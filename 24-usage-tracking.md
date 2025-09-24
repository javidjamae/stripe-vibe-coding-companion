# Usage-Based Billing Components

## Overview

This module covers implementing usage-based billing components, tracking consumption patterns, and integrating usage data with your Stripe billing system. We'll explore the usage tracking patterns found in your codebase.

## Usage Tracking Architecture

Your codebase implements comprehensive usage tracking:

```
Feature Usage → Usage Recording → Aggregation → Billing Integration → Limit Enforcement
```

### Core Usage Components

1. **Usage Recording**: Track feature consumption in real-time
2. **Usage Aggregation**: Summarize usage by billing periods
3. **Limit Enforcement**: Prevent overuse based on plan limits
4. **Overage Billing**: Handle usage beyond plan limits
5. **Usage Analytics**: Provide insights to users and admins

## Usage Data Model

### Database Schema

```sql
-- Usage records table (from your codebase analysis)
CREATE TABLE IF NOT EXISTS public.usage_records (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    user_id UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
    
    -- Usage details
    feature_name TEXT NOT NULL,
    usage_amount INTEGER NOT NULL DEFAULT 1,
    usage_date DATE DEFAULT CURRENT_DATE,
    
    -- Billing period context
    billing_period_start TIMESTAMPTZ,
    billing_period_end TIMESTAMPTZ,
    
    -- Additional context
    metadata JSONB DEFAULT '{}',
    
    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX idx_usage_records_user_feature ON usage_records(user_id, feature_name);
CREATE INDEX idx_usage_records_billing_period ON usage_records(user_id, billing_period_start, billing_period_end);
CREATE INDEX idx_usage_records_date ON usage_records(usage_date);
```

### TypeScript Interfaces

```typescript
// lib/usage-types.ts
export interface UsageRecord {
  id: string
  userId: string
  featureName: string
  usageAmount: number
  usageDate: string
  billingPeriodStart?: string
  billingPeriodEnd?: string
  metadata?: Record<string, any>
  createdAt: string
}

export interface UsageSummary {
  featureName: string
  totalUsage: number
  recordCount: number
  periodStart: string
  periodEnd: string
  planLimit?: number
  overageUsage?: number
  overageCost?: number
}

export interface FeatureUsage {
  computeMinutes: number
  concurrentJobs: number
  apiCalls: number
  storageGB: number
  customFeatures: Record<string, number>
}
```

## Usage Recording Implementation

### Core Usage Recording Function

```typescript
// lib/usage-recorder.ts
export async function recordUsage(
  userId: string,
  featureName: string,
  amount: number = 1,
  metadata: Record<string, any> = {}
): Promise<{ success: boolean; usage?: UsageRecord; error?: string }> {
  
  console.log(`📊 Recording usage: ${featureName} = ${amount} for user ${userId}`)

  try {
    const supabase = createServerUserClient()
    
    // Get current billing period
    const billingPeriod = await getCurrentBillingPeriod(userId)
    
    // Record usage
    const { data, error } = await supabase
      .from('usage_records')
      .insert({
        user_id: userId,
        feature_name: featureName,
        usage_amount: amount,
        billing_period_start: billingPeriod?.start,
        billing_period_end: billingPeriod?.end,
        metadata: {
          ...metadata,
          recorded_at: new Date().toISOString(),
          source: 'app_usage'
        }
      })
      .select()
      .single()

    if (error) {
      console.error('❌ Error recording usage:', error)
      return { success: false, error: error.message }
    }

    console.log('✅ Usage recorded successfully')
    
    // Check if usage exceeds limits
    await checkUsageLimits(userId, featureName)
    
    return { success: true, usage: data }

  } catch (error) {
    console.error('❌ Exception recording usage:', error)
    return { 
      success: false, 
      error: error instanceof Error ? error.message : 'Unknown error' 
    }
  }
}

async function getCurrentBillingPeriod(userId: string): Promise<{
  start: string
  end: string
} | null> {
  const supabase = createServerUserClient()
  
  const { data: subscription } = await supabase
    .from('subscriptions')
    .select('current_period_start, current_period_end')
    .eq('user_id', userId)
    .single()

  if (!subscription) return null

  return {
    start: subscription.current_period_start,
    end: subscription.current_period_end
  }
}
```

### Feature-Specific Usage Recording

```typescript
// lib/feature-usage-recorders.ts
export async function recordComputeMinutes(
  userId: string,
  minutes: number,
  jobId?: string,
  jobType?: string
): Promise<void> {
  await recordUsage(userId, 'compute_minutes', minutes, {
    job_id: jobId,
    job_type: jobType,
    recorded_by: 'job_processor'
  })
}

export async function recordAPICall(
  userId: string,
  endpoint: string,
  responseTime?: number
): Promise<void> {
  await recordUsage(userId, 'api_calls', 1, {
    endpoint,
    response_time_ms: responseTime,
    recorded_by: 'api_middleware'
  })
}

export async function recordConcurrentJob(
  userId: string,
  action: 'start' | 'end',
  jobId: string
): Promise<void> {
  const amount = action === 'start' ? 1 : -1
  
  await recordUsage(userId, 'concurrent_jobs', amount, {
    job_id: jobId,
    action,
    recorded_by: 'job_manager'
  })
}

export async function recordStorageUsage(
  userId: string,
  bytesUsed: number,
  fileType?: string
): Promise<void> {
  const gbUsed = bytesUsed / (1024 * 1024 * 1024) // Convert to GB
  
  await recordUsage(userId, 'storage_gb', gbUsed, {
    bytes_used: bytesUsed,
    file_type: fileType,
    recorded_by: 'storage_manager'
  })
}
```

## Usage Aggregation and Queries

### Usage Summary RPC Function

```sql
-- Database function for usage aggregation
CREATE OR REPLACE FUNCTION get_usage_summary(
  user_uuid UUID,
  period_start TIMESTAMPTZ,
  period_end TIMESTAMPTZ
)
RETURNS TABLE (
  feature_name TEXT,
  total_usage NUMERIC,
  record_count BIGINT,
  first_usage TIMESTAMPTZ,
  last_usage TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    ur.feature_name,
    SUM(ur.usage_amount) as total_usage,
    COUNT(*) as record_count,
    MIN(ur.created_at) as first_usage,
    MAX(ur.created_at) as last_usage
  FROM usage_records ur
  WHERE ur.user_id = user_uuid
    AND ur.created_at >= period_start
    AND ur.created_at < period_end
  GROUP BY ur.feature_name
  ORDER BY ur.feature_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### Usage API Endpoints

```typescript
// usage/summary.ts - Framework-agnostic usage summary
export async function handleUsageSummary(request: Request): Promise<Response> {
  try {
    // Extract user context (implementation varies by framework)
    const user = await getUserFromRequest(request)
    if (!user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const url = new URL(request.url)
    const periodType = url.searchParams.get('period') || 'current' // current, last_month, last_7_days

    // Get billing period based on request
    const period = await getBillingPeriodForUser(user.id, periodType)
    if (!period) {
      return new Response(
        JSON.stringify({ error: 'Unable to determine billing period' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Get usage summary
    const { data: usage, error } = await supabase
      .rpc('get_usage_summary', {
        user_uuid: user.id,
        period_start: period.start,
        period_end: period.end
      })

    if (error) {
      console.error('Usage summary error:', error)
      return new Response(
        JSON.stringify({ error: 'Failed to fetch usage' }),
        { status: 500, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Get plan limits for comparison
    const subscription = await getSubscriptionDetails(user.id)
    const planConfig = subscription ? getPlanConfig(subscription.plan_id) : null

    // Format response with limits and overage information
    const formattedUsage = (usage || []).map((item: any) => {
      const limit = getFeatureLimit(item.feature_name, planConfig)
      const overageUsage = limit ? Math.max(0, item.total_usage - limit) : 0
      const overageCost = calculateOverageCost(item.feature_name, overageUsage, planConfig)

      return {
        featureName: item.feature_name,
        totalUsage: parseFloat(item.total_usage),
        recordCount: parseInt(item.record_count),
        planLimit: limit,
        overageUsage,
        overageCost,
        usagePercent: limit ? (item.total_usage / limit) * 100 : 0,
        firstUsage: item.first_usage,
        lastUsage: item.last_usage
      }
    })

    return new Response(
      JSON.stringify({
        period: {
          start: period.start,
          end: period.end,
          type: periodType
        },
        usage: formattedUsage,
        summary: {
          totalFeatures: formattedUsage.length,
          totalRecords: formattedUsage.reduce((sum, u) => sum + u.recordCount, 0),
          hasOverages: formattedUsage.some(u => u.overageUsage > 0),
          totalOverageCost: formattedUsage.reduce((sum, u) => sum + (u.overageCost || 0), 0)
        }
      }),
      { headers: { 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Usage summary error:', error)
    return new Response(
      JSON.stringify({ error: 'Internal server error' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}

function getFeatureLimit(featureName: string, planConfig: any): number | null {
  if (!planConfig) return null

  switch (featureName) {
    case 'compute_minutes':
      return planConfig.includedComputeMinutes
    case 'concurrent_jobs':
      return planConfig.concurrencyLimit
    case 'api_calls':
      return planConfig.apiCallLimit || null
    case 'storage_gb':
      return planConfig.storageLimit || null
    default:
      return null
  }
}

function calculateOverageCost(
  featureName: string,
  overageAmount: number,
  planConfig: any
): number {
  if (!planConfig || !planConfig.allowOverages || overageAmount <= 0) {
    return 0
  }

  switch (featureName) {
    case 'compute_minutes':
      return (overageAmount * (planConfig.overagePricePerMinuteCents || 0)) / 100
    default:
      return 0
  }
}
```

## Usage Limit Enforcement

### Pre-Usage Validation

```typescript
// lib/usage-enforcement.ts
export async function validateFeatureUsage(
  userId: string,
  featureName: string,
  requestedAmount: number = 1
): Promise<{
  allowed: boolean
  reason?: string
  currentUsage?: number
  limit?: number
  overageAllowed?: boolean
  estimatedCost?: number
}> {
  
  try {
    // Get user's plan and current usage
    const [subscription, currentUsage] = await Promise.all([
      getSubscriptionDetails(userId),
      getCurrentFeatureUsage(userId, featureName)
    ])

    if (!subscription) {
      return { allowed: false, reason: 'No active subscription' }
    }

    const planConfig = getPlanConfig(subscription.plan_id)
    if (!planConfig) {
      return { allowed: false, reason: 'Invalid plan configuration' }
    }

    const limit = getFeatureLimit(featureName, planConfig)
    if (limit === null) {
      // No limit for this feature
      return { allowed: true, currentUsage }
    }

    const projectedUsage = currentUsage + requestedAmount
    
    if (projectedUsage <= limit) {
      // Within limits
      return { 
        allowed: true, 
        currentUsage, 
        limit 
      }
    }

    // Over limit - check if overages are allowed
    if (planConfig.allowOverages) {
      const overageAmount = projectedUsage - limit
      const estimatedCost = calculateOverageCost(featureName, overageAmount, planConfig)
      
      return {
        allowed: true,
        currentUsage,
        limit,
        overageAllowed: true,
        estimatedCost
      }
    }

    // Hard limit exceeded
    return {
      allowed: false,
      reason: `${featureName} limit exceeded`,
      currentUsage,
      limit,
      overageAllowed: false
    }

  } catch (error) {
    console.error('Usage validation error:', error)
    return { 
      allowed: false, 
      reason: 'Unable to validate usage. Please try again.' 
    }
  }
}

async function getCurrentFeatureUsage(
  userId: string,
  featureName: string
): Promise<number> {
  const supabase = createServerUserClient()
  
  const billingPeriod = await getCurrentBillingPeriod(userId)
  if (!billingPeriod) return 0

  const { data } = await supabase
    .rpc('get_feature_usage', {
      user_uuid: userId,
      feature_name: featureName,
      period_start: billingPeriod.start,
      period_end: billingPeriod.end
    })

  return data?.[0]?.total_usage || 0
}
```

### Usage Middleware

```typescript
// lib/usage-middleware.ts
export function withUsageTracking(featureName: string, getAmount?: (req: any) => number) {
  return function usageMiddleware(handler: any) {
    return async function wrappedHandler(req: Request, context: any) {
      try {
        // Get user from request (implementation varies by framework)
        const user = await getUserFromRequest(req)
        
        if (!user) {
          return new Response(
            JSON.stringify({ error: 'Unauthorized' }),
            { status: 401, headers: { 'Content-Type': 'application/json' } }
          )
        }

        // Calculate usage amount
        const amount = getAmount ? getAmount(req) : 1

        // Validate usage before processing
        const validation = await validateFeatureUsage(user.id, featureName, amount)
        
        if (!validation.allowed) {
          return new Response(
            JSON.stringify({
              error: validation.reason,
              usage: {
                current: validation.currentUsage,
                limit: validation.limit,
                overageAllowed: validation.overageAllowed
              }
            }),
            { status: 403, headers: { 'Content-Type': 'application/json' } }
          )
        }

        // Process the request
        const response = await handler(req, context)
        
        // Record usage after successful processing
        if (response.status < 400) {
          await recordUsage(user.id, featureName, amount, {
            endpoint: req.url,
            method: req.method,
            response_status: response.status
          })
        }

        return response

      } catch (error) {
        console.error('Usage middleware error:', error)
        return new Response(
          JSON.stringify({ error: 'Internal server error' }),
          { status: 500, headers: { 'Content-Type': 'application/json' } }
        )
      }
    }
  }
}

// Usage example
// app/api/jobs/transcode/route.ts
export const POST = withUsageTracking('compute_minutes', (req) => {
  // Calculate expected compute minutes based on request
  const body = req.json()
  return estimateComputeMinutes(body.duration, body.quality)
})(async function handler(req: Request) {
  // Your transcode logic here
  return new Response(
    JSON.stringify({ success: true }),
    { headers: { 'Content-Type': 'application/json' } }
  )
})
```

## Usage Display Components

### Real-Time Usage Widget

```typescript
// components/usage/RealTimeUsageWidget.tsx
import { useState, useEffect } from 'react'
import { ChartBarIcon, ExclamationTriangleIcon } from '@heroicons/react/24/outline'

interface RealTimeUsageWidgetProps {
  userId: string
  featureName: string
  refreshInterval?: number // ms
}

export function RealTimeUsageWidget({
  userId,
  featureName,
  refreshInterval = 30000 // 30 seconds
}: RealTimeUsageWidgetProps) {
  const [usage, setUsage] = useState<any>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    loadUsage()
    
    const interval = setInterval(loadUsage, refreshInterval)
    return () => clearInterval(interval)
  }, [userId, featureName, refreshInterval])

  const loadUsage = async () => {
    try {
      const response = await fetch(`/api/usage/${featureName}?userId=${userId}`)
      if (response.ok) {
        const data = await response.json()
        setUsage(data)
      }
    } catch (error) {
      console.error('Failed to load usage:', error)
    } finally {
      setLoading(false)
    }
  }

  if (loading) {
    return <div className="animate-pulse bg-gray-200 rounded h-16 w-full"></div>
  }

  if (!usage) return null

  const usagePercent = usage.limit ? (usage.currentUsage / usage.limit) * 100 : 0
  const isNearLimit = usagePercent >= 80
  const isOverLimit = usagePercent >= 100

  return (
    <div className={`rounded-lg border p-4 ${
      isOverLimit ? 'bg-red-50 border-red-200' :
      isNearLimit ? 'bg-yellow-50 border-yellow-200' :
      'bg-white border-gray-200'
    }`}>
      <div className="flex items-center justify-between mb-2">
        <div className="flex items-center">
          <ChartBarIcon className="h-4 w-4 text-gray-400 mr-2" />
          <span className="text-sm font-medium text-gray-900">
            {featureName.replace('_', ' ').replace(/\b\w/g, l => l.toUpperCase())}
          </span>
        </div>
        {(isNearLimit || isOverLimit) && (
          <ExclamationTriangleIcon className={`h-4 w-4 ${
            isOverLimit ? 'text-red-400' : 'text-yellow-400'
          }`} />
        )}
      </div>

      <div className="flex items-end justify-between mb-2">
        <span className="text-lg font-bold text-gray-900">
          {usage.currentUsage.toLocaleString()}
        </span>
        {usage.limit && (
          <span className="text-sm text-gray-600">
            / {usage.limit.toLocaleString()}
          </span>
        )}
      </div>

      {usage.limit && (
        <div className="w-full bg-gray-200 rounded-full h-2 mb-2">
          <div 
            className={`h-2 rounded-full transition-all ${
              isOverLimit ? 'bg-red-500' :
              isNearLimit ? 'bg-yellow-500' :
              'bg-blue-500'
            }`}
            style={{ width: `${Math.min(100, usagePercent)}%` }}
          ></div>
        </div>
      )}

      <div className="flex justify-between items-center text-xs text-gray-500">
        <span>{usagePercent.toFixed(1)}% used</span>
        <span>Resets: {new Date(usage.periodEnd).toLocaleDateString()}</span>
      </div>

      {/* Overage Information */}
      {isOverLimit && usage.overageAllowed && (
        <div className="mt-2 text-xs text-red-600">
          Overage: {(usage.currentUsage - usage.limit).toLocaleString()} units
          {usage.overageCost && (
            <span className="ml-1">
              (${usage.overageCost.toFixed(2)} estimated)
            </span>
          )}
        </div>
      )}
    </div>
  )
}
```

### Usage History Chart

```typescript
// components/usage/UsageHistoryChart.tsx
import { useState, useEffect } from 'react'
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts'

interface UsageHistoryChartProps {
  userId: string
  featureName: string
  days?: number
}

export function UsageHistoryChart({ 
  userId, 
  featureName, 
  days = 30 
}: UsageHistoryChartProps) {
  const [data, setData] = useState<any[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    loadUsageHistory()
  }, [userId, featureName, days])

  const loadUsageHistory = async () => {
    setLoading(true)
    try {
      const response = await fetch(
        `/api/usage/history?userId=${userId}&feature=${featureName}&days=${days}`
      )
      
      if (response.ok) {
        const result = await response.json()
        setData(result.data || [])
      }
    } catch (error) {
      console.error('Failed to load usage history:', error)
    } finally {
      setLoading(false)
    }
  }

  if (loading) {
    return <div className="animate-pulse bg-gray-200 rounded h-64 w-full"></div>
  }

  return (
    <div className="bg-white rounded-lg border border-gray-200 p-6">
      <h3 className="text-lg font-medium text-gray-900 mb-4">
        {featureName.replace('_', ' ').replace(/\b\w/g, l => l.toUpperCase())} Usage History
      </h3>
      
      <div className="h-64">
        <ResponsiveContainer width="100%" height="100%">
          <LineChart data={data}>
            <CartesianGrid strokeDasharray="3 3" />
            <XAxis 
              dataKey="date" 
              tickFormatter={(value) => new Date(value).toLocaleDateString()}
            />
            <YAxis />
            <Tooltip 
              labelFormatter={(value) => new Date(value).toLocaleDateString()}
              formatter={(value: any) => [value.toLocaleString(), 'Usage']}
            />
            <Line 
              type="monotone" 
              dataKey="usage" 
              stroke="#3B82F6" 
              strokeWidth={2}
              dot={{ fill: '#3B82F6', strokeWidth: 2 }}
            />
          </LineChart>
        </ResponsiveContainer>
      </div>
    </div>
  )
}
```

## Overage Billing Integration

### Overage Calculation and Billing

```typescript
// lib/overage-billing.ts
export async function processOverageBilling(
  userId: string,
  billingPeriodEnd: string
): Promise<{ success: boolean; overageAmount?: number; error?: string }> {
  
  console.log(`💰 Processing overage billing for user ${userId}`)

  try {
    const subscription = await getSubscriptionDetails(userId)
    if (!subscription) {
      return { success: false, error: 'No subscription found' }
    }

    const planConfig = getPlanConfig(subscription.plan_id)
    if (!planConfig?.allowOverages) {
      console.log('Plan does not allow overages')
      return { success: true, overageAmount: 0 }
    }

    // Get usage for the billing period
    const { data: usage } = await supabase
      .rpc('get_usage_summary', {
        user_uuid: userId,
        period_start: subscription.current_period_start,
        period_end: billingPeriodEnd
      })

    if (!usage || usage.length === 0) {
      return { success: true, overageAmount: 0 }
    }

    let totalOverageAmount = 0

    // Calculate overages for each feature
    for (const usageItem of usage) {
      const limit = getFeatureLimit(usageItem.feature_name, planConfig)
      if (limit && usageItem.total_usage > limit) {
        const overageUsage = usageItem.total_usage - limit
        const overageCost = calculateOverageCost(usageItem.feature_name, overageUsage, planConfig)
        totalOverageAmount += overageCost
      }
    }

    if (totalOverageAmount > 0) {
      // Create overage invoice item in Stripe
      await createOverageInvoiceItem(subscription.stripe_customer_id, totalOverageAmount, usage)
    }

    console.log(`✅ Overage billing processed: $${totalOverageAmount.toFixed(2)}`)
    return { success: true, overageAmount: totalOverageAmount }

  } catch (error) {
    console.error('❌ Overage billing failed:', error)
    return { 
      success: false, 
      error: error instanceof Error ? error.message : 'Overage billing failed' 
    }
  }
}

async function createOverageInvoiceItem(
  customerId: string,
  overageAmount: number,
  usageDetails: any[]
): Promise<void> {
  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  // Create invoice item for overages
  await stripe.invoiceItems.create({
    customer: customerId,
    amount: Math.round(overageAmount * 100), // Convert to cents
    currency: 'usd',
    description: 'Usage overages for billing period',
    metadata: {
      type: 'usage_overage',
      billing_period: new Date().toISOString(),
      usage_details: JSON.stringify(usageDetails)
    }
  })

  console.log('✅ Overage invoice item created')
}
```

## Testing Usage Tracking

### Usage Recording Tests

```typescript
// __tests__/lib/usage-recorder.test.ts
import { recordUsage, validateFeatureUsage } from '@/lib/usage-recorder'

describe('Usage Recording', () => {
  it('should record compute minutes usage', async () => {
    const result = await recordUsage('user123', 'compute_minutes', 150, {
      job_id: 'job_456',
      job_type: 'video_transcode'
    })

    expect(result.success).toBe(true)
    expect(result.usage?.featureName).toBe('compute_minutes')
    expect(result.usage?.usageAmount).toBe(150)
  })

  it('should validate usage against plan limits', async () => {
    // Mock user with starter plan (2000 minute limit)
    const validation = await validateFeatureUsage('user123', 'compute_minutes', 500)

    expect(validation.allowed).toBe(true)
    expect(validation.limit).toBe(2000)
  })

  it('should reject usage when hard limits are exceeded', async () => {
    // Mock user with free plan (100 minute limit, no overages)
    const validation = await validateFeatureUsage('user123', 'compute_minutes', 150)

    expect(validation.allowed).toBe(false)
    expect(validation.reason).toContain('limit exceeded')
  })

  it('should allow overages for plans that support them', async () => {
    // Mock user with starter plan (allows overages)
    const validation = await validateFeatureUsage('user123', 'compute_minutes', 2500)

    expect(validation.allowed).toBe(true)
    expect(validation.overageAllowed).toBe(true)
    expect(validation.estimatedCost).toBeGreaterThan(0)
  })
})
```

### E2E Usage Tests

```typescript
// cypress/e2e/usage/usage-tracking.cy.ts
describe('Usage Tracking', () => {
  beforeEach(() => {
    cy.seedStarterUser({ email: 'usage-test@example.com' })
    cy.login('usage-test@example.com')
  })

  it('should track and display usage in real-time', () => {
    cy.visit('/dashboard')

    // Should show usage widgets
    cy.get('[data-testid="usage-widget-compute-minutes"]').should('be.visible')
    cy.get('[data-testid="usage-widget-concurrent-jobs"]').should('be.visible')

    // Create a job to generate usage
    cy.get('[data-testid="create-job-button"]').click()
    cy.get('[data-testid="job-type-transcode"]').click()
    cy.get('[data-testid="submit-job"]').click()

    // Usage should update
    cy.get('[data-testid="usage-widget-compute-minutes"]').should('not.contain', '0')

    // Visit billing page to see detailed usage
    cy.visit('/billing')
    cy.get('[data-testid="tab-usage"]').click()
    cy.get('[data-testid="detailed-usage-chart"]').should('be.visible')
  })

  it('should show usage warnings when approaching limits', () => {
    // Seed user with high usage
    cy.seedUserWithHighUsage({ 
      email: 'high-usage@example.com',
      computeMinutes: 1800 // 90% of starter limit
    })
    cy.login('high-usage@example.com')

    cy.visit('/billing')

    // Should show usage warning
    cy.get('[data-testid="usage-warning"]').should('be.visible')
    cy.get('[data-testid="usage-warning"]').should('contain', 'Approaching Usage Limit')
    cy.get('[data-testid="upgrade-suggestion"]').should('be.visible')
  })

  it('should handle overage scenarios', () => {
    // Seed user with overage usage
    cy.seedUserWithOverageUsage({ 
      email: 'overage@example.com',
      computeMinutes: 2500 // Over starter limit
    })
    cy.login('overage@example.com')

    cy.visit('/billing')

    // Should show overage information
    cy.get('[data-testid="overage-alert"]').should('be.visible')
    cy.get('[data-testid="overage-amount"]').should('contain', '$')
    cy.get('[data-testid="overage-explanation"]').should('be.visible')
  })
})
```

## Next Steps

In the next module, we'll cover managing payment methods and handling failed payment scenarios.

## Key Takeaways

- Implement comprehensive usage tracking for all billable features
- Use database functions for efficient usage aggregation
- Validate usage against plan limits before processing requests
- Display real-time usage information to users
- Handle overage billing automatically for plans that support it
- Use middleware to track usage consistently across API endpoints
- Provide detailed usage analytics and history
- Show clear warnings when approaching usage limits
- Test usage tracking and enforcement thoroughly
- Integrate usage data with billing and plan management systems
