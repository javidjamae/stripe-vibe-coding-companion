# Database Schema Design for Stripe Integration

## Overview

This module covers the database schema patterns used in your codebase for storing subscription, billing, and user data. Understanding these patterns is crucial for building a robust billing system that stays in sync with Stripe.

## Core Database Tables

Based on our core billing system architecture, here are the essential tables for Stripe integration:

### 1. Users Table

```sql
CREATE TABLE IF NOT EXISTS public.users (
    id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    first_name TEXT,
    last_name TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
```

**Purpose**: Extends Supabase auth.users with additional profile information
**Key Points**:
- References Supabase auth.users for authentication
- Stores user profile data
- One-to-one relationship with auth users

### 2. Subscriptions Table

```sql
CREATE TABLE IF NOT EXISTS public.subscriptions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    
    -- Stripe identifiers
    stripe_subscription_id TEXT,
    stripe_customer_id TEXT,
    stripe_price_id TEXT,
    
    -- Plan information
    plan_id TEXT NOT NULL DEFAULT 'free',
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'canceled', 'past_due', 'unpaid', 'trialing', 'incomplete', 'incomplete_expired')),
    
    -- Billing period information
    current_period_start TIMESTAMPTZ,
    current_period_end TIMESTAMPTZ,
    cancel_at_period_end BOOLEAN DEFAULT false,
    
    -- Flexible metadata storage
    metadata JSONB DEFAULT '{}',
    
    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
```

**Purpose**: Central table for subscription management
**Key Features**:
- Stores Stripe subscription details
- Tracks billing periods and status
- Flexible metadata for complex scenarios (scheduled changes, upgrades)
- Proper constraints for data integrity

### 3. Usage Records Table

```sql
CREATE TABLE IF NOT EXISTS public.usage_records (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    
    -- Flexible usage tracking
    product TEXT DEFAULT 'core',
    metric TEXT NOT NULL,             -- e.g., compute_minutes, storage_bytes, api_calls
    unit TEXT NOT NULL,               -- e.g., minutes, bytes, calls
    amount NUMERIC NOT NULL CHECK (amount >= 0),
    
    -- Source tracking
    source_type TEXT,                 -- e.g., job, api_call, storage
    source_id TEXT,                   -- flexible source reference
    job_id UUID,                      -- optional linkage when source is a job
    idempotency_key TEXT,             -- prevent duplicate events
    
    -- Metadata for additional context
    metadata JSONB DEFAULT '{}',
    
    -- Legacy compatibility (for migration from other systems)
    billable_minutes NUMERIC,
    operation TEXT,
    period_start TIMESTAMPTZ,
    period_end TIMESTAMPTZ,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Purpose**: Flexible usage tracking for billing and quota enforcement
**Key Features**:
- Supports multiple metrics and products
- Idempotency keys prevent duplicate usage events
- Links usage to billing periods
- Aggregatable for billing calculations
- Legacy compatibility for migrations

### 4. API Keys Table

```sql
CREATE TABLE IF NOT EXISTS public.api_keys (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    user_id UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
    
    -- Key information
    name TEXT NOT NULL,
    key_hash TEXT UNIQUE NOT NULL,
    is_active BOOLEAN DEFAULT true,
    
    -- Usage tracking
    last_used_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    
    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
```

**Purpose**: Manage user API keys for programmatic access
**Key Features**:
- Hashed key storage for security
- Usage tracking and expiration
- Per-user key management

## Subscription Metadata Patterns

Your codebase uses JSONB metadata extensively for complex subscription scenarios:

### Scheduled Plan Changes

```typescript
interface ScheduledChange {
  planId: string
  interval: 'month' | 'year'
  priceId: string | null
  effectiveAt: string // ISO timestamp
}

// Storing scheduled change in metadata
const scheduledChange: ScheduledChange = {
  planId: 'free',
  interval: 'month',
  priceId: getStripePriceId('free', 'month'),
  effectiveAt: new Date(periodEnd * 1000).toISOString(),
}

await supabase
  .from('subscriptions')
  .update({
    cancel_at_period_end: true,
    metadata: {
      scheduled_change: scheduledChange,
    }
  })
  .eq('id', subscriptionId)
```

### Interval Switch Metadata

```typescript
// For complex upgrade scenarios with interval changes
const metadata = {
  scheduled_change: {
    planId: 'scale',
    interval: 'month',
    priceId: 'price_monthly_scale',
    effectiveAt: '2024-02-01T00:00:00Z'
  },
  upgrade_context: {
    original_plan: 'pro',
    original_interval: 'year',
    upgrade_type: 'plan_and_interval'
  }
}
```

## Row Level Security (RLS) Policies

Your database uses RLS to ensure users can only access their own data:

### Users Table Policies

```sql
-- Users can view their own profile
CREATE POLICY "Users can view own profile" ON users
  FOR SELECT USING (auth.uid() = id);

-- Users can update their own profile
CREATE POLICY "Users can update own profile" ON users
  FOR UPDATE USING (auth.uid() = id);
```

### Subscriptions Table Policies

```sql
-- Users can view their own subscriptions
CREATE POLICY "Users can view own subscriptions" ON subscriptions
  FOR SELECT USING (auth.uid() = user_id);

-- Service role can manage all subscriptions (for webhooks)
CREATE POLICY "Service role can manage subscriptions" ON subscriptions
  FOR ALL USING (auth.role() = 'service_role');
```

### Usage Records Policies

```sql
-- Users can view their own usage
CREATE POLICY "Users can view own usage" ON usage_records
  FOR SELECT USING (auth.uid() = user_id);

-- Users can insert their own usage
CREATE POLICY "Users can insert own usage" ON usage_records
  FOR INSERT WITH CHECK (auth.uid() = user_id);
```

## Database Functions for Complex Queries

Your codebase includes RPC functions for complex subscription queries:

### Get User Active Subscription

```sql
CREATE OR REPLACE FUNCTION get_user_active_subscription(user_uuid UUID)
RETURNS TABLE (
  id UUID,
  user_id UUID,
  stripe_subscription_id TEXT,
  plan_type TEXT,
  status TEXT,
  current_period_start TIMESTAMPTZ,
  current_period_end TIMESTAMPTZ,
  cancel_at_period_end BOOLEAN,
  metadata JSONB,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT s.*
  FROM subscriptions s
  WHERE s.user_id = user_uuid
    AND s.status IN ('active', 'trialing', 'past_due')
  ORDER BY s.updated_at DESC
  LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### Get Usage Summary

```sql
CREATE OR REPLACE FUNCTION get_usage_summary(
  user_uuid UUID,
  period_start TIMESTAMPTZ,
  period_end TIMESTAMPTZ
)
RETURNS TABLE (
  feature_name TEXT,
  total_usage BIGINT,
  usage_count BIGINT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    ur.feature_name,
    SUM(ur.usage_amount) as total_usage,
    COUNT(*) as usage_count
  FROM usage_records ur
  WHERE ur.user_id = user_uuid
    AND ur.created_at >= period_start
    AND ur.created_at < period_end
  GROUP BY ur.feature_name
  ORDER BY ur.feature_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

## Data Synchronization Patterns

### Webhook-Driven Updates

Your webhook handlers keep the database in sync with Stripe:

```typescript
// Invoice payment succeeded - update subscription status
export async function handleInvoicePaymentPaid(invoice: any) {
  const { data, error } = await supabase
    .from('subscriptions')
    .update({
      status: 'active',
      current_period_start: isoOrNull(invoice.period_start as number | null),
      current_period_end: isoOrNull(invoice.period_end as number | null),
      updated_at: new Date().toISOString(),
    })
    .eq('stripe_subscription_id', invoice.subscription)
    .select()
    .single()
}
```

### Subscription Schedule Updates

```typescript
// Clear scheduled change metadata when entering new phase
export async function handleSubscriptionScheduleUpdated(schedule: any) {
  const phases = schedule?.phases || []
  const currentPhaseStart = schedule?.current_phase?.start_date
  
  if (phases.length && currentPhaseStart) {
    const currentIndex = phases.findIndex(p => p?.start_date === currentPhaseStart)
    
    // When entering phase 2, clear the scheduled change
    if (currentIndex >= 1) {
      const currentMeta = (row?.metadata || {}) as Record<string, any>
      if (currentMeta && 'scheduled_change' in currentMeta) {
        const nextMeta = { ...currentMeta }
        delete nextMeta.scheduled_change

        await supabase
          .from('subscriptions')
          .update({ 
            metadata: nextMeta, 
            updated_at: new Date().toISOString() 
          })
          .eq('id', subscriptionId)
      }
    }
  }
}
```

## Indexing Strategy

Essential indexes for performance:

```sql
-- Subscription lookups by user
CREATE INDEX idx_subscriptions_user_id ON subscriptions(user_id);

-- Subscription lookups by Stripe ID
CREATE INDEX idx_subscriptions_stripe_id ON subscriptions(stripe_subscription_id);

-- Usage queries by user and date
CREATE INDEX idx_usage_records_user_date ON usage_records(user_id, usage_date);

-- Usage queries by billing period
CREATE INDEX idx_usage_records_billing_period ON usage_records(user_id, billing_period_start, billing_period_end);

-- API key lookups
CREATE INDEX idx_api_keys_hash ON api_keys(key_hash) WHERE is_active = true;
```

## Data Integrity Constraints

### Subscription Constraints

```sql
-- Ensure valid subscription status
ALTER TABLE subscriptions 
ADD CONSTRAINT valid_status 
CHECK (status IN ('active', 'canceled', 'past_due', 'unpaid', 'trialing', 'incomplete', 'incomplete_expired'));

-- Ensure billing periods make sense
ALTER TABLE subscriptions 
ADD CONSTRAINT valid_billing_period 
CHECK (current_period_start IS NULL OR current_period_end IS NULL OR current_period_start < current_period_end);
```

### Usage Record Constraints

```sql
-- Ensure positive usage amounts
ALTER TABLE usage_records 
ADD CONSTRAINT positive_usage 
CHECK (usage_amount > 0);

-- Ensure valid billing period relationship
ALTER TABLE usage_records 
ADD CONSTRAINT valid_usage_billing_period 
CHECK (billing_period_start IS NULL OR billing_period_end IS NULL OR billing_period_start < billing_period_end);
```

## Migration Patterns

### Adding New Fields

```sql
-- Add new field with default value
ALTER TABLE subscriptions 
ADD COLUMN billing_interval TEXT DEFAULT 'month' 
CHECK (billing_interval IN ('month', 'year'));

-- Update existing records
UPDATE subscriptions 
SET billing_interval = 'year' 
WHERE stripe_price_id IN (
  SELECT stripe_price_id 
  FROM plan_prices 
  WHERE interval = 'year'
);
```

### Schema Evolution

```sql
-- Add metadata field for new features
ALTER TABLE subscriptions 
ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}';

-- Create index for metadata queries
CREATE INDEX IF NOT EXISTS idx_subscriptions_metadata_gin 
ON subscriptions USING gin(metadata);
```

## Backup and Recovery Considerations

### Critical Data Protection

- **Subscription data** - Core billing relationship
- **Usage records** - Required for billing calculations
- **User profiles** - Customer information
- **API keys** - Service access credentials

### Backup Strategy

```sql
-- Regular backup of critical tables
pg_dump --table=subscriptions --table=users --table=usage_records your_database

-- Point-in-time recovery capability
-- Configure WAL archiving for production
```

## Testing Database Schema

### Test Data Setup

```sql
-- Create test user
INSERT INTO users (id, email, first_name, last_name) 
VALUES ('123e4567-e89b-12d3-a456-426614174000', 'test@example.com', 'Test', 'User');

-- Create test subscription
INSERT INTO subscriptions (user_id, plan_id, status, stripe_subscription_id) 
VALUES ('123e4567-e89b-12d3-a456-426614174000', 'starter', 'active', 'sub_test123');

-- Create test usage
INSERT INTO usage_records (user_id, feature_name, usage_amount) 
VALUES ('123e4567-e89b-12d3-a456-426614174000', 'compute_minutes', 150);
```

## Next Steps

In the next module, we'll cover API architecture patterns for handling Stripe operations and webhook processing.

## Key Takeaways

- Use JSONB metadata for flexible subscription state management
- Implement proper RLS policies for data security
- Create database functions for complex queries
- Design for webhook-driven synchronization
- Include proper indexing for performance
- Plan for schema evolution and migrations
- Protect critical billing data with appropriate constraints
