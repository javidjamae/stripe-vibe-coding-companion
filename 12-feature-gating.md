# Plan-Based Feature Gating

## Overview

This module covers implementing plan-based feature access control, including how to gate features based on subscription tiers, handle usage limits, and provide upgrade prompts when users hit plan restrictions.

## Feature Gating Architecture

Your feature gating system should control access at multiple levels:

```
Plan Configuration → Feature Definitions → Access Control → UI Components → Usage Enforcement
```

### Core Components

1. **Feature Definitions**: Define what features are available per plan
2. **Access Control Hooks**: Check feature access in components
3. **Usage Tracking**: Monitor feature usage against limits
4. **Upgrade Prompts**: Guide users to higher plans when needed
5. **Enforcement Mechanisms**: Block or limit feature usage

## Feature Definition System

### Plan-Based Feature Configuration

```typescript
// lib/feature-definitions.ts
export interface FeatureDefinition {
  id: string
  name: string
  description: string
  category: 'core' | 'advanced' | 'enterprise'
  plans: {
    [planId: string]: {
      enabled: boolean
      limit?: number
      softLimit?: boolean // Allow overages with warnings
    }
  }
}

export const features: FeatureDefinition[] = [
  {
    id: 'concurrent_jobs',
    name: 'Concurrent Jobs',
    description: 'Number of jobs that can run simultaneously',
    category: 'core',
    plans: {
      free: { enabled: true, limit: 1 },
      starter: { enabled: true, limit: 3 },
      pro: { enabled: true, limit: 10 },
      scale: { enabled: true, limit: 40 }
    }
  },
  {
    id: 'compute_minutes',
    name: 'Compute Minutes',
    description: 'Processing time allocation per month',
    category: 'core',
    plans: {
      free: { enabled: true, limit: 100 },
      starter: { enabled: true, limit: 2000, softLimit: true },
      pro: { enabled: true, limit: 12000, softLimit: true },
      scale: { enabled: true, limit: 60000, softLimit: true }
    }
  },
  {
    id: 'api_access',
    name: 'API Access',
    description: 'Programmatic access via REST API',
    category: 'core',
    plans: {
      free: { enabled: true },
      starter: { enabled: true },
      pro: { enabled: true },
      scale: { enabled: true }
    }
  },
  {
    id: 'webhook_notifications',
    name: 'Webhook Notifications',
    description: 'Real-time job completion notifications',
    category: 'advanced',
    plans: {
      free: { enabled: false },
      starter: { enabled: true },
      pro: { enabled: true },
      scale: { enabled: true }
    }
  },
  {
    id: 'priority_processing',
    name: 'Priority Processing',
    description: 'Jobs processed ahead of standard queue',
    category: 'advanced',
    plans: {
      free: { enabled: false },
      starter: { enabled: false },
      pro: { enabled: true },
      scale: { enabled: true }
    }
  },
  {
    id: 'custom_integrations',
    name: 'Custom Integrations',
    description: 'Custom workflow integrations and connectors',
    category: 'enterprise',
    plans: {
      free: { enabled: false },
      starter: { enabled: false },
      pro: { enabled: false },
      scale: { enabled: true }
    }
  },
  {
    id: 'advanced_analytics',
    name: 'Advanced Analytics',
    description: 'Detailed usage analytics and reporting',
    category: 'advanced',
    plans: {
      free: { enabled: false },
      starter: { enabled: false },
      pro: { enabled: true },
      scale: { enabled: true }
    }
  },
  {
    id: 'bulk_operations',
    name: 'Bulk Operations',
    description: 'Process multiple files in batch operations',
    category: 'advanced',
    plans: {
      free: { enabled: false },
      starter: { enabled: true, limit: 10 },
      pro: { enabled: true, limit: 100 },
      scale: { enabled: true, limit: 1000 }
    }
  }
]

export function getFeatureDefinition(featureId: string): FeatureDefinition | null {
  return features.find(f => f.id === featureId) || null
}

export function getFeatureAccess(featureId: string, planId: string) {
  const feature = getFeatureDefinition(featureId)
  if (!feature) return { enabled: false }
  
  return feature.plans[planId] || { enabled: false }
}

export function getPlanFeatures(planId: string): FeatureDefinition[] {
  return features.filter(feature => 
    feature.plans[planId]?.enabled === true
  )
}
```

## Access Control Hooks

### Feature Access Hook

```typescript
// hooks/useFeatureAccess.ts
import { useState, useEffect } from 'react'
import { useAuth } from './useAuth'
import { getFeatureAccess, getFeatureDefinition } from '@/lib/feature-definitions'
import { getSubscriptionDetails } from '@/lib/billing'

export interface FeatureAccess {
  enabled: boolean
  limit?: number
  softLimit?: boolean
  currentUsage?: number
  remaining?: number
  exceeded?: boolean
  upgradeRequired?: boolean
}

export function useFeatureAccess(featureId: string): {
  access: FeatureAccess
  loading: boolean
  checkAccess: () => Promise<void>
} {
  const [access, setAccess] = useState<FeatureAccess>({ enabled: false })
  const [loading, setLoading] = useState(true)
  const { user } = useAuth()

  useEffect(() => {
    if (user) {
      checkFeatureAccess()
    } else {
      setAccess({ enabled: false, upgradeRequired: true })
      setLoading(false)
    }
  }, [user, featureId])

  const checkFeatureAccess = async () => {
    if (!user) return

    setLoading(true)
    try {
      // Get user's current plan
      const subscription = await getSubscriptionDetails(user.id)
      const planId = subscription?.plan_id || 'free'

      // Get feature configuration for this plan
      const featureConfig = getFeatureAccess(featureId, planId)
      
      if (!featureConfig.enabled) {
        setAccess({ 
          enabled: false, 
          upgradeRequired: true 
        })
        return
      }

      // If feature has limits, check current usage
      if (featureConfig.limit !== undefined) {
        const currentUsage = await getCurrentFeatureUsage(user.id, featureId)
        const remaining = Math.max(0, featureConfig.limit - currentUsage)
        const exceeded = currentUsage >= featureConfig.limit

        setAccess({
          enabled: true,
          limit: featureConfig.limit,
          softLimit: featureConfig.softLimit,
          currentUsage,
          remaining,
          exceeded: exceeded && !featureConfig.softLimit,
          upgradeRequired: exceeded && !featureConfig.softLimit
        })
      } else {
        // No limits, feature is fully available
        setAccess({ enabled: true })
      }

    } catch (error) {
      console.error('Feature access check failed:', error)
      setAccess({ enabled: false })
    } finally {
      setLoading(false)
    }
  }

  return {
    access,
    loading,
    checkAccess: checkFeatureAccess
  }
}

async function getCurrentFeatureUsage(userId: string, featureId: string): Promise<number> {
  try {
    const response = await fetch(`/api/usage/${featureId}?userId=${userId}`)
    if (!response.ok) return 0
    
    const data = await response.json()
    return data.currentUsage || 0
  } catch (error) {
    console.error('Failed to get feature usage:', error)
    return 0
  }
}
```

### Plan Comparison Hook

```typescript
// hooks/usePlanComparison.ts
import { useState, useEffect } from 'react'
import { useAuth } from './useAuth'
import { getPlanFeatures, getFeatureAccess } from '@/lib/feature-definitions'
import { getAllPlans } from '@/lib/plan-config'

export function usePlanComparison() {
  const [currentPlan, setCurrentPlan] = useState<string>('free')
  const [planFeatures, setPlanFeatures] = useState<any>({})
  const [loading, setLoading] = useState(true)
  const { user } = useAuth()

  useEffect(() => {
    loadPlanComparison()
  }, [user])

  const loadPlanComparison = async () => {
    setLoading(true)
    try {
      // Get current plan
      let userPlan = 'free'
      if (user) {
        const subscription = await getSubscriptionDetails(user.id)
        userPlan = subscription?.plan_id || 'free'
      }
      setCurrentPlan(userPlan)

      // Get all plans and their features
      const allPlans = getAllPlans()
      const comparison: any = {}

      Object.keys(allPlans).forEach(planId => {
        comparison[planId] = {
          plan: allPlans[planId],
          features: getPlanFeatures(planId).map(feature => ({
            ...feature,
            access: getFeatureAccess(feature.id, planId)
          }))
        }
      })

      setPlanFeatures(comparison)
    } catch (error) {
      console.error('Failed to load plan comparison:', error)
    } finally {
      setLoading(false)
    }
  }

  return {
    currentPlan,
    planFeatures,
    loading,
    reload: loadPlanComparison
  }
}
```

## Feature Gating Components

### Feature Gate Component

```typescript
// components/FeatureGate.tsx
import { ReactNode } from 'react'
import { useFeatureAccess } from '@/hooks/useFeatureAccess'
import { UpgradePrompt } from './UpgradePrompt'
import { UsageLimitWarning } from './UsageLimitWarning'

interface FeatureGateProps {
  featureId: string
  children: ReactNode
  fallback?: ReactNode
  showUpgradePrompt?: boolean
  showUsageWarning?: boolean
}

export function FeatureGate({
  featureId,
  children,
  fallback,
  showUpgradePrompt = true,
  showUsageWarning = true
}: FeatureGateProps) {
  const { access, loading } = useFeatureAccess(featureId)

  if (loading) {
    return (
      <div className="animate-pulse bg-gray-200 rounded h-8 w-32"></div>
    )
  }

  // Feature not enabled for current plan
  if (!access.enabled || access.upgradeRequired) {
    if (showUpgradePrompt) {
      return <UpgradePrompt featureId={featureId} />
    }
    return fallback || null
  }

  // Feature enabled but usage exceeded (hard limit)
  if (access.exceeded && !access.softLimit) {
    if (showUpgradePrompt) {
      return <UpgradePrompt featureId={featureId} reason="limit_exceeded" />
    }
    return fallback || null
  }

  // Feature enabled but approaching limit (soft limit)
  if (access.softLimit && access.remaining !== undefined && access.remaining <= 5) {
    return (
      <div>
        {showUsageWarning && (
          <UsageLimitWarning
            featureId={featureId}
            remaining={access.remaining}
            limit={access.limit}
          />
        )}
        {children}
      </div>
    )
  }

  // Feature fully available
  return <>{children}</>
}
```

### Upgrade Prompt Component

```typescript
// components/UpgradePrompt.tsx
import { useState } from 'react'
import { ArrowUpIcon, XMarkIcon } from '@heroicons/react/24/outline'
import { getFeatureDefinition } from '@/lib/feature-definitions'
import { useCurrentPlan } from '@/hooks/useCurrentPlan'

interface UpgradePromptProps {
  featureId: string
  reason?: 'not_available' | 'limit_exceeded'
  compact?: boolean
  dismissible?: boolean
}

export function UpgradePrompt({
  featureId,
  reason = 'not_available',
  compact = false,
  dismissible = false
}: UpgradePromptProps) {
  const [dismissed, setDismissed] = useState(false)
  const { currentPlan } = useCurrentPlan()
  const feature = getFeatureDefinition(featureId)

  if (dismissed || !feature) return null

  // Find the lowest plan that enables this feature
  const availablePlans = Object.entries(feature.plans)
    .filter(([_, config]) => config.enabled)
    .map(([planId]) => planId)

  const suggestedPlan = availablePlans.find(planId => 
    canUpgradeTo(currentPlan || 'free', planId)
  )

  const getMessage = () => {
    switch (reason) {
      case 'limit_exceeded':
        return `You've reached your ${feature.name} limit.`
      default:
        return `${feature.name} is not available on your current plan.`
    }
  }

  const getActionText = () => {
    if (suggestedPlan) {
      const planConfig = getPlanConfig(suggestedPlan)
      return `Upgrade to ${planConfig?.name}`
    }
    return 'View Plans'
  }

  if (compact) {
    return (
      <div className="inline-flex items-center space-x-2 text-sm text-gray-600">
        <span>{getMessage()}</span>
        <button
          onClick={() => window.location.href = '/pricing'}
          className="text-blue-600 hover:text-blue-700 font-medium"
        >
          {getActionText()}
        </button>
      </div>
    )
  }

  return (
    <div className="bg-blue-50 border border-blue-200 rounded-lg p-4">
      <div className="flex items-start">
        <div className="flex-shrink-0">
          <ArrowUpIcon className="h-5 w-5 text-blue-400" />
        </div>
        
        <div className="ml-3 flex-1">
          <h3 className="text-sm font-medium text-blue-800">
            {feature.name} Upgrade Required
          </h3>
          <p className="mt-1 text-sm text-blue-700">
            {getMessage()} {feature.description}
          </p>
          
          <div className="mt-3">
            <button
              onClick={() => window.location.href = '/pricing'}
              className="bg-blue-600 text-white px-4 py-2 rounded-md text-sm font-medium hover:bg-blue-700"
            >
              {getActionText()}
            </button>
          </div>
        </div>

        {dismissible && (
          <div className="flex-shrink-0 ml-3">
            <button
              onClick={() => setDismissed(true)}
              className="text-blue-400 hover:text-blue-600"
            >
              <XMarkIcon className="h-5 w-5" />
            </button>
          </div>
        )}
      </div>
    </div>
  )
}
```

### Usage Limit Warning

```typescript
// components/UsageLimitWarning.tsx
import { ExclamationTriangleIcon } from '@heroicons/react/24/outline'
import { getFeatureDefinition } from '@/lib/feature-definitions'

interface UsageLimitWarningProps {
  featureId: string
  remaining: number
  limit?: number
  showUpgradeOption?: boolean
}

export function UsageLimitWarning({
  featureId,
  remaining,
  limit,
  showUpgradeOption = true
}: UsageLimitWarningProps) {
  const feature = getFeatureDefinition(featureId)
  if (!feature) return null

  const percentage = limit ? ((limit - remaining) / limit) * 100 : 0

  return (
    <div className="bg-yellow-50 border border-yellow-200 rounded-md p-3 mb-4">
      <div className="flex items-center">
        <ExclamationTriangleIcon className="h-4 w-4 text-yellow-400 mr-2" />
        <div className="flex-1">
          <p className="text-sm text-yellow-800">
            <strong>{remaining}</strong> {feature.name.toLowerCase()} remaining this month
            {limit && (
              <span className="ml-1">
                ({percentage.toFixed(0)}% used)
              </span>
            )}
          </p>
          
          {showUpgradeOption && (
            <button
              onClick={() => window.location.href = '/pricing'}
              className="text-sm text-yellow-700 hover:text-yellow-900 underline mt-1"
            >
              Upgrade for higher limits
            </button>
          )}
        </div>
      </div>
    </div>
  )
}
```

## Usage Enforcement

### Usage Tracking API

```typescript
// usage/feature-usage.ts - Framework-agnostic usage tracking
import { createServerUserClient } from './lib/supabase-clients'

export async function handleGetFeatureUsage(
  request: Request,
  featureId: string
): Promise<Response> {
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
    const userId = url.searchParams.get('userId') || user.id

    // Get current billing period
    const { data: subscription } = await supabase
      .from('subscriptions')
      .select('current_period_start, current_period_end')
      .eq('user_id', userId)
      .single()

    if (!subscription) {
      return new Response(
        JSON.stringify({ currentUsage: 0, periodStart: null, periodEnd: null }),
        { headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Get usage for current period
    const { data: usage } = await supabase
      .rpc('get_feature_usage', {
        user_uuid: userId,
        feature_name: featureId,
        period_start: subscription.current_period_start,
        period_end: subscription.current_period_end
      })

    const currentUsage = usage?.[0]?.total_usage || 0

    return new Response(
      JSON.stringify({
        currentUsage,
        periodStart: subscription.current_period_start,
        periodEnd: subscription.current_period_end
      }),
      { headers: { 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Usage fetch error:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to fetch usage' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}

export async function handleRecordFeatureUsage(
  request: Request,
  featureId: string
): Promise<Response> {
  try {
    // Extract user context (implementation varies by framework)
    const user = await getUserFromRequest(request)
    if (!user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }
    const { amount = 1, metadata = {} } = await request.json()

    // Check if user can use this feature
    const access = await checkFeatureAccess(user.id, featureId)
    if (!access.enabled || (access.exceeded && !access.softLimit)) {
      return new Response(
        JSON.stringify({ 
          error: 'Feature not available or limit exceeded',
          access 
        }),
        { status: 403, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const { amount = 1, metadata = {} } = await request.json()

    // Record usage using core patterns
    const supabase = createSupabaseClient()
    const { data, error } = await supabase
      .from('usage_records')
      .insert({
        user_id: user.id,
        metric: featureId,
        unit: 'usage',
        amount,
        metadata,
        period_start: access.periodStart,
        period_end: access.periodEnd
      })
      .select()
      .single()

    if (error) {
      console.error('Usage recording error:', error)
      return new Response(
        JSON.stringify({ error: 'Failed to record usage' }),
        { status: 500, headers: { 'Content-Type': 'application/json' } }
      )
    }

    return new Response(
      JSON.stringify({ 
        success: true, 
        usage: data,
        remainingAccess: await checkFeatureAccess(user.id, featureId)
      }),
      { headers: { 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Usage recording error:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to record usage' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}

async function checkFeatureAccess(userId: string, featureId: string) {
  // Implementation similar to useFeatureAccess hook
  // Returns current access status including limits and usage
}
```

### Feature Usage Hook

```typescript
// hooks/useFeatureUsage.ts
import { useState } from 'react'
import { useFeatureAccess } from './useFeatureAccess'

export function useFeatureUsage(featureId: string) {
  const [recording, setRecording] = useState(false)
  const { access, checkAccess } = useFeatureAccess(featureId)

  const recordUsage = async (amount: number = 1, metadata: any = {}) => {
    setRecording(true)
    try {
      const response = await fetch(`/api/usage/${featureId}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ amount, metadata }),
      })

      const data = await response.json()

      if (!response.ok) {
        throw new Error(data.error || 'Failed to record usage')
      }

      // Refresh access status
      await checkAccess()

      return data
    } catch (error) {
      console.error('Usage recording failed:', error)
      throw error
    } finally {
      setRecording(false)
    }
  }

  const canUse = access.enabled && (!access.exceeded || access.softLimit)

  return {
    access,
    canUse,
    recordUsage,
    recording
  }
}
```

## Feature-Specific Components

### Concurrent Jobs Gate

```typescript
// components/features/ConcurrentJobsGate.tsx
import { useFeatureUsage } from '@/hooks/useFeatureUsage'
import { FeatureGate } from '@/components/FeatureGate'

interface ConcurrentJobsGateProps {
  children: React.ReactNode
  onJobStart?: () => void
}

export function ConcurrentJobsGate({ children, onJobStart }: ConcurrentJobsGateProps) {
  const { access, canUse, recordUsage } = useFeatureUsage('concurrent_jobs')

  const handleJobStart = async () => {
    if (!canUse) return false

    try {
      await recordUsage(1, { action: 'job_started' })
      onJobStart?.()
      return true
    } catch (error) {
      console.error('Failed to start job:', error)
      return false
    }
  }

  return (
    <FeatureGate featureId="concurrent_jobs">
      <div>
        {access.limit && (
          <div className="mb-2 text-sm text-gray-600">
            Concurrent jobs: {access.currentUsage || 0} / {access.limit}
          </div>
        )}
        <div onClick={handleJobStart}>
          {children}
        </div>
      </div>
    </FeatureGate>
  )
}
```

### API Access Gate

```typescript
// components/features/APIAccessGate.tsx
export function APIAccessGate({ children }: { children: React.ReactNode }) {
  return (
    <FeatureGate 
      featureId="api_access"
      fallback={
        <div className="text-center p-8 bg-gray-50 rounded-lg">
          <h3 className="text-lg font-medium text-gray-900 mb-2">
            API Access Required
          </h3>
          <p className="text-gray-600 mb-4">
            API access is available on all paid plans.
          </p>
          <button
            onClick={() => window.location.href = '/pricing'}
            className="bg-blue-600 text-white px-4 py-2 rounded-md hover:bg-blue-700"
          >
            View Plans
          </button>
        </div>
      }
    >
      {children}
    </FeatureGate>
  )
}
```

## Testing Feature Gating

### Unit Tests

```typescript
// __tests__/hooks/useFeatureAccess.test.ts
import { renderHook, waitFor } from '@testing-library/react'
import { useFeatureAccess } from '@/hooks/useFeatureAccess'

// Mock the dependencies
jest.mock('@/hooks/useAuth', () => ({
  useAuth: () => ({ user: { id: 'test-user' } })
}))

jest.mock('@/lib/billing', () => ({
  getSubscriptionDetails: jest.fn().mockResolvedValue({ plan_id: 'starter' })
}))

describe('useFeatureAccess', () => {
  it('should return access for enabled features', async () => {
    const { result } = renderHook(() => useFeatureAccess('api_access'))

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    expect(result.current.access.enabled).toBe(true)
    expect(result.current.access.upgradeRequired).toBeFalsy()
  })

  it('should require upgrade for disabled features', async () => {
    const { result } = renderHook(() => useFeatureAccess('priority_processing'))

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })

    expect(result.current.access.enabled).toBe(false)
    expect(result.current.access.upgradeRequired).toBe(true)
  })
})
```

### Integration Tests

```typescript
// cypress/e2e/feature-gating.cy.ts
describe('Feature Gating', () => {
  beforeEach(() => {
    cy.seedStarterUser({ email: 'starter@example.com' })
    cy.login('starter@example.com')
  })

  it('should allow access to starter features', () => {
    cy.visit('/dashboard')

    // Should show webhook settings (available on starter)
    cy.get('[data-testid="webhook-settings"]').should('be.visible')

    // Should not show priority processing (pro+ only)
    cy.get('[data-testid="priority-processing"]').should('not.exist')
  })

  it('should show upgrade prompts for unavailable features', () => {
    cy.visit('/features/analytics')

    // Should show upgrade prompt for advanced analytics
    cy.get('[data-testid="upgrade-prompt"]').should('be.visible')
    cy.get('[data-testid="upgrade-prompt"]').should('contain', 'Advanced Analytics')

    // Click upgrade button
    cy.get('[data-testid="upgrade-button"]').click()
    cy.url().should('include', '/pricing')
  })

  it('should enforce usage limits', () => {
    cy.visit('/jobs/bulk-upload')

    // Upload files up to limit
    for (let i = 0; i < 10; i++) {
      cy.get('[data-testid="file-input"]').attachFile('test-file.mp4')
    }

    // Should show limit reached message
    cy.get('[data-testid="limit-reached"]').should('be.visible')

    // Should disable upload button
    cy.get('[data-testid="upload-button"]').should('be.disabled')
  })
})
```

## Next Steps

In the next module, we'll cover immediate upgrade flows with proration handling, building on the feature gating foundation to guide users through plan upgrades.

## Key Takeaways

- Define features with plan-specific access rules and limits
- Use hooks for clean feature access checking in components
- Implement feature gates to control UI access
- Provide clear upgrade prompts when features aren't available
- Track usage against plan limits with soft and hard enforcement
- Show usage warnings as users approach limits
- Test feature gating thoroughly across different plan scenarios
- Use feature-specific components for complex gating logic
- Record usage events for billing and analytics
- Handle edge cases like trial periods and plan changes gracefully
