# Multi-Tenant Billing Architectures

## Overview

This module covers implementing multi-tenant billing architectures for SaaS applications, including user isolation, subscription management across tenants, and billing data separation. Based on production-tested patterns, we'll explore multi-tenancy strategies that scale with your business.

## Multi-Tenancy Models

### User-Level Tenancy (Your Current Approach)

Your codebase implements user-level tenancy where each user has their own subscription:

```typescript
// Your actual user-subscription relationship
interface Subscription {
  id: string
  userId: string  // Direct user relationship
  planId: string
  stripeSubscriptionId: string | null
  stripeCustomerId: string | null
  // ... other fields
}

// Your RLS pattern for user isolation
CREATE POLICY "Users can view own subscriptions" ON subscriptions
  FOR SELECT USING (auth.uid() = user_id);
```

**Benefits of User-Level Tenancy:**
- Simple implementation and reasoning
- Clear data ownership and isolation
- Easy to implement with RLS
- Straightforward billing relationship

### Organization-Level Tenancy (Alternative Approach)

If you wanted to support teams/organizations:

```sql
-- Organization-based multi-tenancy schema
CREATE TABLE organizations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  slug TEXT UNIQUE NOT NULL,
  owner_id UUID REFERENCES auth.users(id) NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE organization_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(organization_id, user_id)
);

-- Subscription belongs to organization, not individual user
CREATE TABLE organization_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
  stripe_subscription_id TEXT UNIQUE,
  stripe_customer_id TEXT,
  plan_id TEXT NOT NULL,
  status TEXT NOT NULL,
  -- ... other subscription fields
);
```

## Data Isolation Patterns

### RLS for Multi-Tenant Data

```sql
-- Enhanced RLS policies for multi-tenant data
-- Organizations: Users can only see organizations they belong to
CREATE POLICY "Users can view own organizations" ON organizations
  FOR SELECT USING (
    id IN (
      SELECT organization_id 
      FROM organization_members 
      WHERE user_id = auth.uid()
    )
  );

-- Organization subscriptions: Users can only see their org's subscription
CREATE POLICY "Users can view org subscriptions" ON organization_subscriptions
  FOR SELECT USING (
    organization_id IN (
      SELECT organization_id 
      FROM organization_members 
      WHERE user_id = auth.uid()
    )
  );

-- Usage data: Isolated by organization
CREATE POLICY "Users can view org usage" ON usage_ledger
  FOR SELECT USING (
    organization_id IN (
      SELECT organization_id 
      FROM organization_members 
      WHERE user_id = auth.uid()
    )
  );
```

### Tenant Context Management

```typescript
// lib/multi-tenant/context.ts
export class TenantContext {
  constructor(
    public userId: string,
    public organizationId?: string,
    public role?: 'owner' | 'admin' | 'member'
  ) {}

  static async fromRequest(request: Request): Promise<TenantContext> {
    const supabase = createServerUserClient()
    
    const { data: { user }, error } = await supabase.auth.getUser()
    if (error || !user) {
      throw new Error('Unauthorized')
    }

    // Get organization context from header or default to user's primary org
    const orgHeader = request.headers.get('x-organization-id')
    
    if (orgHeader) {
      // Validate user has access to this organization
      const { data: membership } = await supabase
        .from('organization_members')
        .select('role')
        .eq('organization_id', orgHeader)
        .eq('user_id', user.id)
        .single()

      if (!membership) {
        throw new Error('Access denied to organization')
      }

      return new TenantContext(user.id, orgHeader, membership.role)
    }

    // Default to user-level tenancy (your current approach)
    return new TenantContext(user.id)
  }

  async getSubscription(): Promise<any> {
    const supabase = createServerUserClient()

    if (this.organizationId) {
      // Organization-level subscription
      const { data, error } = await supabase
        .from('organization_subscriptions')
        .select('*')
        .eq('organization_id', this.organizationId)
        .single()

      if (error) throw error
      return data
    } else {
      // User-level subscription (your current pattern)
      const { data, error } = await supabase
        .rpc('get_user_active_subscription', { user_uuid: this.userId })

      if (error) throw error
      return data?.[0] || null
    }
  }

  canManageBilling(): boolean {
    // User-level: user can always manage their own billing
    if (!this.organizationId) return true
    
    // Organization-level: only owners and admins can manage billing
    return this.role === 'owner' || this.role === 'admin'
  }
}
```

## Multi-Tenant Billing APIs

### Tenant-Aware Upgrade API

```typescript
// app/api/billing/upgrade/route.ts (Enhanced for multi-tenancy)
export async function POST(req: Request) {
  try {
    // Get tenant context
    const tenantContext = await TenantContext.fromRequest(req)
    
    // Verify user can manage billing
    if (!tenantContext.canManageBilling()) {
      return new Response(
      JSON.stringify({ 
        error: 'Insufficient permissions to manage billing' 
      ),
      { status: 403 })
    }

    const { newPlanId, billingInterval } = await req.json()
    
    // Get subscription in tenant context
    const subscription = await tenantContext.getSubscription()
    if (!subscription) {
      return new Response(
      JSON.stringify({ error: 'No subscription found' ),
      { status: 404 })
    }

    // Validate upgrade is allowed
    if (!canUpgradeTo(subscription.plan_id, newPlanId)) {
      return new Response(
      JSON.stringify({ 
        error: `Cannot upgrade from ${subscription.plan_id} to ${newPlanId}` 
      ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    // Process upgrade (same logic as your current implementation)
    const priceId = getStripePriceId(newPlanId, billingInterval || 'month')
    if (!priceId) {
      return new Response(
      JSON.stringify({ error: 'Invalid plan or billing interval' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    // Update Stripe subscription
    const stripeSubscription = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
    const subscriptionItemId = stripeSubscription.items.data[0].id

    const updatedSubscription = await stripe.subscriptions.update(subscription.stripe_subscription_id, {
      items: [{ id: subscriptionItemId, price: priceId }],
      proration_behavior: 'create_prorations'
    })

    // Update database (tenant-aware)
    const tableName = tenantContext.organizationId ? 'organization_subscriptions' : 'subscriptions'
    const { error } = await supabase
      .from(tableName)
      .update({
        plan_id: newPlanId,
        stripe_price_id: priceId,
        status: updatedSubscription.status,
        updated_at: new Date().toISOString()
      })
      .eq('stripe_subscription_id', subscription.stripe_subscription_id)

    if (error) {
      console.error('Failed to update subscription:', error)
      return new Response(
      JSON.stringify({ error: 'Failed to update subscription' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
    }

    // Log billing event with tenant context
    await logBillingEvent('upgrade', {
      userId: tenantContext.userId,
      organizationId: tenantContext.organizationId,
      fromPlan: subscription.plan_id,
      toPlan: newPlanId,
      subscriptionId: subscription.stripe_subscription_id
    })

    return new Response(
      JSON.stringify({
      success: true,
      message: `Successfully upgraded to ${newPlanId}`
    })

  } catch (error) {
    console.error('Upgrade error:', error)
    return new Response(
      JSON.stringify({ error: 'Upgrade failed' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Usage Tracking in Multi-Tenant Systems

### Tenant-Aware Usage Tracking

```typescript
// lib/usage/multi-tenant-usage.ts
export class MultiTenantUsageTracker {
  async trackUsage(
    tenantContext: TenantContext,
    metric: string,
    amount: number,
    metadata: any = {}
  ) {
    const supabase = createServerUserClient()

    // Determine the tenant ID for usage tracking
    const tenantId = tenantContext.organizationId || tenantContext.userId
    const tenantType = tenantContext.organizationId ? 'organization' : 'user'

    // Get current billing period
    const subscription = await tenantContext.getSubscription()
    const periodStart = subscription?.current_period_start || new Date(Date.now() - 30 * 24 * 60 * 60 * 1000)
    const periodEnd = subscription?.current_period_end || new Date()

    // Record usage
    const { error } = await supabase
      .from('usage_ledger')
      .insert({
        user_id: tenantContext.userId,
        tenant_id: tenantId,
        tenant_type: tenantType,
        metric: metric,
        amount: amount,
        period_start: periodStart,
        period_end: periodEnd,
        metadata: {
          ...metadata,
          organization_id: tenantContext.organizationId,
          user_role: tenantContext.role
        },
        created_at: new Date().toISOString()
      })

    if (error) {
      console.error('Failed to track usage:', error)
      throw error
    }

    // Check if usage exceeds plan limits
    await this.checkUsageLimits(tenantContext, metric)
  }

  async getUsageForTenant(
    tenantContext: TenantContext,
    metric: string,
    periodStart?: Date,
    periodEnd?: Date
  ) {
    const supabase = createServerUserClient()
    const tenantId = tenantContext.organizationId || tenantContext.userId

    const { data: usage, error } = await supabase
      .from('usage_ledger')
      .select('amount, created_at')
      .eq('tenant_id', tenantId)
      .eq('metric', metric)
      .gte('created_at', (periodStart || new Date(Date.now() - 30 * 24 * 60 * 60 * 1000)).toISOString())
      .lt('created_at', (periodEnd || new Date()).toISOString())

    if (error) {
      console.error('Failed to get usage:', error)
      return 0
    }

    return usage?.reduce((sum, record) => sum + record.amount, 0) || 0
  }

  private async checkUsageLimits(tenantContext: TenantContext, metric: string) {
    const subscription = await tenantContext.getSubscription()
    if (!subscription) return

    const planConfig = getPlanConfig(subscription.plan_id)
    if (!planConfig) return

    // Get usage for current period
    const currentUsage = await this.getUsageForTenant(tenantContext, metric)
    
    // Check against plan limits
    const limit = this.getPlanLimit(planConfig, metric)
    if (limit && currentUsage > limit) {
      await this.handleUsageOverage(tenantContext, metric, currentUsage, limit)
    }
  }

  private getPlanLimit(planConfig: any, metric: string): number | null {
    switch (metric) {
      case 'compute_minutes':
        return planConfig.includedComputeMinutes
      case 'api_calls':
        return planConfig.includedApiCalls || null
      case 'storage_bytes':
        return planConfig.includedStorageBytes || null
      default:
        return null
    }
  }

  private async handleUsageOverage(
    tenantContext: TenantContext,
    metric: string,
    currentUsage: number,
    limit: number
  ) {
    const subscription = await tenantContext.getSubscription()
    const planConfig = getPlanConfig(subscription.plan_id)

    if (planConfig?.allowOverages) {
      // Calculate overage charges
      const overage = currentUsage - limit
      const overageRate = planConfig.overagePricePerMinuteCents || 0
      const overageAmount = overage * overageRate

      console.log(`💰 Usage overage detected: ${overage} ${metric} at $${overageAmount/100}`)
      
      // Record overage for billing
      await this.recordOverageCharge(tenantContext, metric, overage, overageAmount)
    } else {
      // Hard limit - block further usage
      console.log(`🚫 Usage limit exceeded: ${currentUsage}/${limit} ${metric}`)
      
      await this.notifyUsageLimitExceeded(tenantContext, metric, currentUsage, limit)
      throw new Error(`Usage limit exceeded for ${metric}`)
    }
  }

  private async recordOverageCharge(
    tenantContext: TenantContext,
    metric: string,
    overage: number,
    amount: number
  ) {
    const supabase = createServerUserClient()

    await supabase
      .from('overage_charges')
      .insert({
        tenant_id: tenantContext.organizationId || tenantContext.userId,
        tenant_type: tenantContext.organizationId ? 'organization' : 'user',
        metric: metric,
        overage_amount: overage,
        charge_amount_cents: amount,
        billing_period_start: new Date().toISOString(), // Current period
        created_at: new Date().toISOString()
      })
  }
}
```

## Tenant Data Isolation

### Database Schema for Multi-Tenancy

```sql
-- Enhanced schema with tenant isolation
CREATE TABLE tenants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type TEXT NOT NULL CHECK (type IN ('user', 'organization')),
  name TEXT NOT NULL,
  slug TEXT UNIQUE,
  owner_id UUID REFERENCES auth.users(id),
  settings JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Tenant memberships
CREATE TABLE tenant_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member', 'billing_admin')),
  permissions JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(tenant_id, user_id)
);

-- Tenant subscriptions
CREATE TABLE tenant_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  stripe_subscription_id TEXT UNIQUE,
  stripe_customer_id TEXT,
  plan_id TEXT NOT NULL,
  status TEXT NOT NULL,
  current_period_start TIMESTAMPTZ,
  current_period_end TIMESTAMPTZ,
  cancel_at_period_end BOOLEAN DEFAULT false,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Tenant usage tracking
CREATE TABLE tenant_usage (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id), -- Who generated the usage
  metric TEXT NOT NULL,
  amount NUMERIC NOT NULL,
  period_start TIMESTAMPTZ NOT NULL,
  period_end TIMESTAMPTZ NOT NULL,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);
```

### RLS Policies for Tenant Isolation

```sql
-- Tenant access policies
CREATE POLICY "Users can access their tenants" ON tenants
  FOR ALL USING (
    id IN (
      SELECT tenant_id 
      FROM tenant_members 
      WHERE user_id = auth.uid()
    )
  );

-- Subscription access based on tenant membership
CREATE POLICY "Users can access tenant subscriptions" ON tenant_subscriptions
  FOR SELECT USING (
    tenant_id IN (
      SELECT tenant_id 
      FROM tenant_members 
      WHERE user_id = auth.uid()
    )
  );

-- Billing management requires admin role
CREATE POLICY "Billing admins can manage subscriptions" ON tenant_subscriptions
  FOR UPDATE USING (
    tenant_id IN (
      SELECT tenant_id 
      FROM tenant_members 
      WHERE user_id = auth.uid()
      AND role IN ('owner', 'admin', 'billing_admin')
    )
  );

-- Usage visibility based on tenant membership
CREATE POLICY "Users can view tenant usage" ON tenant_usage
  FOR SELECT USING (
    tenant_id IN (
      SELECT tenant_id 
      FROM tenant_members 
      WHERE user_id = auth.uid()
    )
  );
```

## Multi-Tenant Billing Logic

### Tenant-Aware Checkout Sessions

```typescript
// lib/billing/multi-tenant-checkout.ts
export async function createTenantCheckoutSession(
  tenantContext: TenantContext,
  planId: string,
  billingInterval: 'month' | 'year' = 'month'
) {
  if (!tenantContext.canManageBilling()) {
    throw new Error('Insufficient permissions to manage billing')
  }

  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  // Get or create Stripe customer for tenant
  let stripeCustomerId: string

  const existingSubscription = await tenantContext.getSubscription()
  if (existingSubscription?.stripe_customer_id) {
    stripeCustomerId = existingSubscription.stripe_customer_id
  } else {
    // Create new customer for tenant
    const customerData: any = {
      metadata: {
        tenant_id: tenantContext.organizationId || tenantContext.userId,
        tenant_type: tenantContext.organizationId ? 'organization' : 'user',
        owner_id: tenantContext.userId
      }
    }

    if (tenantContext.organizationId) {
      // Organization customer
      const { data: org } = await supabase
        .from('tenants')
        .select('name, settings')
        .eq('id', tenantContext.organizationId)
        .single()

      customerData.name = org?.name
      customerData.email = org?.settings?.billing_email || `billing+${tenantContext.organizationId}@yourcompany.com`
    } else {
      // User customer (your current pattern)
      const { data: user } = await supabase.auth.admin.getUserById(tenantContext.userId)
      customerData.email = user.user?.email
    }

    const customer = await stripe.customers.create(customerData)
    stripeCustomerId = customer.id
  }

  // Create checkout session
  const priceId = getStripePriceId(planId, billingInterval)
  if (!priceId) {
    throw new Error('Invalid plan or billing interval')
  }

  const session = await stripe.checkout.sessions.create({
    customer: stripeCustomerId,
    line_items: [{ price: priceId, quantity: 1 }],
    mode: 'subscription',
    success_url: `${process.env.APP_URL}/billing?success=true`,
    cancel_url: `${process.env.APP_URL}/billing?canceled=true`,
    metadata: {
      tenant_id: tenantContext.organizationId || tenantContext.userId,
      tenant_type: tenantContext.organizationId ? 'organization' : 'user',
      user_id: tenantContext.userId,
      plan_id: planId
    },
    subscription_data: {
      metadata: {
        tenant_id: tenantContext.organizationId || tenantContext.userId,
        tenant_type: tenantContext.organizationId ? 'organization' : 'user',
        plan_id: planId
      }
    }
  })

  return { url: session.url }
}
```

## Tenant Billing Webhooks

### Multi-Tenant Webhook Processing

```typescript
// Enhanced webhook handlers for multi-tenant systems
export async function handleInvoicePaymentPaid(invoice: any) {
  console.log('📝 Processing invoice_payment.paid for multi-tenant system')
  
  if (!invoice.subscription) {
    console.log('❌ No subscription ID found in invoice')
    return
  }

  try {
    const supabase = createServerServiceRoleClient()

    // Determine tenant type from subscription metadata
    const stripeSubscription = await stripe.subscriptions.retrieve(invoice.subscription)
    const tenantType = stripeSubscription.metadata?.tenant_type || 'user'
    const tenantId = stripeSubscription.metadata?.tenant_id

    if (!tenantId) {
      console.error('❌ No tenant ID found in subscription metadata')
      return
    }

    // Update appropriate subscription table
    const tableName = tenantType === 'organization' ? 'tenant_subscriptions' : 'subscriptions'
    const tenantIdColumn = tenantType === 'organization' ? 'tenant_id' : 'user_id'

    const { data, error } = await supabase
      .from(tableName)
      .update({
        status: 'active',
        current_period_start: new Date(invoice.period_start * 1000).toISOString(),
        current_period_end: new Date(invoice.period_end * 1000).toISOString(),
        updated_at: new Date().toISOString()
      })
      .eq('stripe_subscription_id', invoice.subscription)
      .select()
      .single()

    if (error) {
      console.error('❌ Error updating subscription:', error)
      return
    }

    console.log(`✅ Successfully updated ${tenantType} subscription ${invoice.subscription}`)

    // Send notification to tenant billing contacts
    await notifyTenantBillingContacts(tenantId, tenantType, 'payment_succeeded', {
      amount: invoice.amount_paid / 100,
      currency: invoice.currency,
      periodStart: new Date(invoice.period_start * 1000).toISOString(),
      periodEnd: new Date(invoice.period_end * 1000).toISOString()
    })

    return data

  } catch (error) {
    console.error('❌ Exception in multi-tenant handleInvoicePaymentPaid:', error)
  }
}

async function notifyTenantBillingContacts(
  tenantId: string,
  tenantType: 'user' | 'organization',
  eventType: string,
  eventData: any
) {
  try {
    const supabase = createServerServiceRoleClient()

    if (tenantType === 'organization') {
      // Get organization billing contacts
      const { data: members } = await supabase
        .from('tenant_members')
        .select(`
          user_id,
          role,
          user:auth.users(email)
        `)
        .eq('tenant_id', tenantId)
        .in('role', ['owner', 'admin', 'billing_admin'])

      // Send notifications to billing contacts
      for (const member of members || []) {
        await sendBillingNotification(member.user.email, eventType, eventData)
      }
    } else {
      // User-level tenant
      const { data: user } = await supabase.auth.admin.getUserById(tenantId)
      if (user.user?.email) {
        await sendBillingNotification(user.user.email, eventType, eventData)
      }
    }

  } catch (error) {
    console.error('Failed to notify tenant billing contacts:', error)
  }
}
```

## Tenant Management APIs

### Tenant Creation and Management

```typescript
// app/api/tenants/route.ts
export async function POST(request: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    const { name, type = 'organization' } = await request.json()

    if (!name || typeof name !== 'string') {
      return new Response(
      JSON.stringify({ error: 'Tenant name is required' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    // Create tenant
    const slug = name.toLowerCase().replace(/[^a-z0-9]/g, '-')
    
    const { data: tenant, error: tenantError } = await supabase
      .from('tenants')
      .insert({
        type,
        name,
        slug,
        owner_id: user.id,
        settings: {
          billing_email: user.email,
          created_by: user.id
        }
      })
      .select()
      .single()

    if (tenantError) {
      console.error('Failed to create tenant:', tenantError)
      return new Response(
      JSON.stringify({ error: 'Failed to create tenant' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
    }

    // Add user as owner
    const { error: memberError } = await supabase
      .from('tenant_members')
      .insert({
        tenant_id: tenant.id,
        user_id: user.id,
        role: 'owner'
      })

    if (memberError) {
      console.error('Failed to add tenant owner:', memberError)
      return new Response(
      JSON.stringify({ error: 'Failed to add tenant owner' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
    }

    // Create free subscription for new tenant
    const { error: subError } = await supabase
      .from('tenant_subscriptions')
      .insert({
        tenant_id: tenant.id,
        plan_id: 'free',
        status: 'active'
      })

    if (subError) {
      console.error('Failed to create tenant subscription:', subError)
      return new Response(
      JSON.stringify({ error: 'Failed to create tenant subscription' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
    }

    return new Response(
      JSON.stringify({
      success: true,
      tenant: {
        id: tenant.id,
        name: tenant.name,
        slug: tenant.slug,
        type: tenant.type
      }
    })

  } catch (error) {
    console.error('Tenant creation error:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to create tenant' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Billing Permissions and Roles

### Role-Based Billing Access

```typescript
// lib/multi-tenant/permissions.ts
export class TenantPermissions {
  static canManageBilling(role: string): boolean {
    return ['owner', 'admin', 'billing_admin'].includes(role)
  }

  static canViewBilling(role: string): boolean {
    return ['owner', 'admin', 'billing_admin', 'member'].includes(role)
  }

  static canManageMembers(role: string): boolean {
    return ['owner', 'admin'].includes(role)
  }

  static canViewUsage(role: string): boolean {
    return ['owner', 'admin', 'billing_admin', 'member'].includes(role)
  }

  static async validateBillingPermission(
    userId: string,
    tenantId: string,
    requiredPermission: 'view' | 'manage'
  ): Promise<boolean> {
    const supabase = createServerUserClient()

    const { data: membership } = await supabase
      .from('tenant_members')
      .select('role')
      .eq('tenant_id', tenantId)
      .eq('user_id', userId)
      .single()

    if (!membership) {
      return false
    }

    switch (requiredPermission) {
      case 'view':
        return this.canViewBilling(membership.role)
      case 'manage':
        return this.canManageBilling(membership.role)
      default:
        return false
    }
  }
}
```

### Permission Middleware

```typescript
// middleware/tenant-permissions.ts
export function withTenantPermissions(
  requiredPermission: 'view' | 'manage'
) {
  return function(handler: any) {
    return async function(request: Request) {
      try {
        const tenantContext = await TenantContext.fromRequest(request)
        
        if (tenantContext.organizationId) {
          const hasPermission = await TenantPermissions.validateBillingPermission(
            tenantContext.userId,
            tenantContext.organizationId,
            requiredPermission
          )

          if (!hasPermission) {
            await logSecurityEvent('insufficient_billing_permissions', {
              userId: tenantContext.userId,
              tenantId: tenantContext.organizationId,
              requiredPermission,
              userRole: tenantContext.role
            }, 'medium')

            return new Response(
      JSON.stringify({ 
              error: `Insufficient permissions for billing ${requiredPermission}` 
            ),
      { status: 403 })
          }
        }

        // Add tenant context to request
        request.tenantContext = tenantContext
        
        return await handler(request)

      } catch (error) {
        console.error('Permission validation error:', error)
        return new Response(
      JSON.stringify({ error: 'Permission validation failed' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
      }
    }
  }
}

// Usage in API routes
export const POST = withTenantPermissions('manage')(async function(request: Request) {
  const tenantContext = request.tenantContext
  
  // ... billing logic with tenant context
})
```

## Multi-Tenant Usage Aggregation

### Tenant Usage Reporting

```typescript
// lib/reporting/tenant-usage.ts
export class TenantUsageReporter {
  async generateTenantUsageReport(
    tenantId: string,
    periodStart: Date,
    periodEnd: Date
  ) {
    const supabase = createServerServiceRoleClient()

    // Get tenant info
    const { data: tenant } = await supabase
      .from('tenants')
      .select('name, type')
      .eq('id', tenantId)
      .single()

    // Get usage by metric
    const { data: usage } = await supabase
      .from('tenant_usage')
      .select('metric, amount, user_id, created_at, metadata')
      .eq('tenant_id', tenantId)
      .gte('created_at', periodStart.toISOString())
      .lt('created_at', periodEnd.toISOString())

    // Aggregate by metric
    const usageByMetric = usage?.reduce((acc, record) => {
      if (!acc[record.metric]) {
        acc[record.metric] = {
          total: 0,
          count: 0,
          byUser: {}
        }
      }
      
      acc[record.metric].total += record.amount
      acc[record.metric].count += 1
      
      if (!acc[record.metric].byUser[record.user_id]) {
        acc[record.metric].byUser[record.user_id] = 0
      }
      acc[record.metric].byUser[record.user_id] += record.amount
      
      return acc
    }, {} as any) || {}

    // Get subscription and plan limits
    const subscription = await this.getTenantSubscription(tenantId)
    const planConfig = subscription ? getPlanConfig(subscription.plan_id) : null

    return {
      tenant: {
        id: tenantId,
        name: tenant?.name,
        type: tenant?.type
      },
      period: {
        start: periodStart.toISOString(),
        end: periodEnd.toISOString()
      },
      subscription: subscription ? {
        planId: subscription.plan_id,
        status: subscription.status,
        limits: {
          computeMinutes: planConfig?.includedComputeMinutes,
          allowOverages: planConfig?.allowOverages
        }
      } : null,
      usage: usageByMetric,
      summary: {
        totalMetrics: Object.keys(usageByMetric).length,
        totalUsage: Object.values(usageByMetric).reduce((sum: number, metric: any) => 
          sum + metric.total, 0),
        uniqueUsers: new Set(usage?.map(u => u.user_id) || []).size
      }
    }
  }

  private async getTenantSubscription(tenantId: string) {
    const supabase = createServerServiceRoleClient()
    
    // Try organization subscription first
    let { data: subscription } = await supabase
      .from('tenant_subscriptions')
      .select('*')
      .eq('tenant_id', tenantId)
      .single()

    if (!subscription) {
      // Fall back to user subscription
      const { data } = await supabase
        .from('subscriptions')
        .select('*')
        .eq('user_id', tenantId)
        .single()
      
      subscription = data
    }

    return subscription
  }
}
```

## Alternative: Simplified Multi-Tenancy

If you want to add basic team features to your current user-based system:

### Team Extension of User Model

```sql
-- Lightweight team extension to your current schema
CREATE TABLE teams (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  owner_id UUID REFERENCES auth.users(id) NOT NULL,
  subscription_id UUID REFERENCES subscriptions(id), -- Share subscription
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE team_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id UUID REFERENCES teams(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(team_id, user_id)
);

-- Teams share the owner's subscription
CREATE POLICY "Team members can view shared subscription" ON subscriptions
  FOR SELECT USING (
    auth.uid() = user_id OR
    auth.uid() IN (
      SELECT tm.user_id 
      FROM teams t
      JOIN team_members tm ON t.id = tm.team_id
      WHERE t.subscription_id = subscriptions.id
    )
  );
```

## Next Steps

In the next module, we'll cover tax handling with Stripe Tax for international billing.

## Key Takeaways

- **Start with user-level tenancy** for simplicity (your current approach)
- **Use RLS policies** for robust data isolation between tenants
- **Implement role-based permissions** for billing management
- **Track usage at the tenant level** for accurate billing
- **Use tenant context** throughout your billing APIs
- **Handle tenant metadata** in Stripe subscriptions and customers
- **Validate permissions** before allowing billing operations
- **Aggregate usage reporting** by tenant for insights
- **Plan for tenant growth** with scalable database design
- **Consider team features** as lightweight extension to user model
