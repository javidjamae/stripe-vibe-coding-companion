# Managing Complex Scheduled Plan Changes

## Overview

This module covers managing complex scheduled plan changes, including how to handle multiple pending changes, cancel existing schedules, and coordinate between Stripe subscription schedules and your database state.

## Scheduled Change Architecture

Your codebase implements a sophisticated system for managing scheduled changes:

```
User Action → Validation → Schedule Creation → Database Update → UI Display → Webhook Processing
```

### Key Components

1. **Scheduled Change Metadata**: Store pending changes in subscription metadata
2. **Subscription Schedules**: Use Stripe schedules for complex timing
3. **Cancel-First Flow**: Handle conflicting scheduled changes
4. **UI State Management**: Display pending changes consistently
5. **Webhook Synchronization**: Keep database in sync with Stripe

## Scheduled Change Data Structure

### Metadata Schema

```typescript
// lib/scheduled-changes.ts
export interface ScheduledChange {
  planId: string
  interval: 'month' | 'year'
  priceId: string | null
  effectiveAt: string // ISO timestamp
  reason?: 'downgrade' | 'interval_change' | 'cancellation'
  context?: {
    original_plan?: string
    original_interval?: string
    change_type?: string
    schedule_id?: string
  }
}

export interface SubscriptionMetadata {
  scheduled_change?: ScheduledChange
  upgrade_context?: {
    original_plan: string
    original_interval: string
    upgrade_type: string
  }
  downgrade_context?: {
    original_plan: string
    original_interval: string
    downgrade_type: string
    schedule_id?: string
  }
  interval_change_history?: Array<{
    from_interval: string
    to_interval: string
    completed_at: string
    plan_id: string
  }>
}
```

### Database Storage Pattern

```typescript
// Store scheduled change in subscription metadata
const scheduledChange: ScheduledChange = {
  planId: 'free',
  interval: 'month',
  priceId: getStripePriceId('free', 'month'),
  effectiveAt: new Date(periodEnd * 1000).toISOString(),
  reason: 'downgrade',
  context: {
    original_plan: currentPlan,
    original_interval: currentInterval,
    change_type: 'simple_downgrade'
  }
}

await supabase
  .from('subscriptions')
  .update({
    cancel_at_period_end: true, // For simple downgrades
    metadata: {
      scheduled_change: scheduledChange
    },
    updated_at: new Date().toISOString()
  })
  .eq('id', subscriptionId)
```

## Scheduled Change Management

### Create Scheduled Change

```typescript
// lib/scheduled-change-manager.ts
export async function createScheduledChange(
  subscriptionId: string,
  change: Omit<ScheduledChange, 'effectiveAt'>,
  options: {
    useSchedule?: boolean
    cancelExisting?: boolean
    effectiveAt?: string
  } = {}
): Promise<{ success: boolean; scheduleId?: string; error?: string }> {
  
  try {
    const supabase = createServerServiceRoleClient()
    
    // Get current subscription
    const { data: subscription, error } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('id', subscriptionId)
      .single()

    if (error || !subscription) {
      return { success: false, error: 'Subscription not found' }
    }

    // Cancel existing scheduled change if requested
    if (options.cancelExisting) {
      await cancelExistingScheduledChange(subscription)
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    let scheduleId: string | undefined
    let effectiveAt = options.effectiveAt

    if (options.useSchedule) {
      // Create Stripe subscription schedule
      const result = await createStripeSchedule(stripe, subscription, change)
      scheduleId = result.scheduleId
      effectiveAt = result.effectiveAt
    } else {
      // Use cancel_at_period_end approach
      await stripe.subscriptions.update(subscription.stripe_subscription_id, {
        cancel_at_period_end: true
      })
      
      // Get effective date from current period end
      const stripeSubscription = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
      effectiveAt = new Date(stripeSubscription.current_period_end * 1000).toISOString()
    }

    // Store scheduled change in database
    const scheduledChange: ScheduledChange = {
      ...change,
      effectiveAt: effectiveAt!,
      context: {
        ...change.context,
        schedule_id: scheduleId,
        created_at: new Date().toISOString()
      }
    }

    const { error: updateError } = await supabase
      .from('subscriptions')
      .update({
        cancel_at_period_end: !options.useSchedule, // Only set for non-schedule approaches
        metadata: {
          scheduled_change: scheduledChange
        },
        updated_at: new Date().toISOString()
      })
      .eq('id', subscriptionId)

    if (updateError) {
      console.error('❌ Error storing scheduled change:', updateError)
      return { success: false, error: 'Failed to store scheduled change' }
    }

    console.log('✅ Scheduled change created successfully')
    return { success: true, scheduleId }

  } catch (error) {
    console.error('❌ Error creating scheduled change:', error)
    return { 
      success: false, 
      error: error instanceof Error ? error.message : 'Unknown error' 
    }
  }
}

async function createStripeSchedule(
  stripe: Stripe,
  subscription: any,
  change: Omit<ScheduledChange, 'effectiveAt'>
): Promise<{ scheduleId: string; effectiveAt: string }> {
  
  // Get current subscription from Stripe
  const stripeSubscription = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
  
  // Create schedule from subscription
  const schedule = await stripe.subscriptionSchedules.create({
    from_subscription: subscription.stripe_subscription_id,
  })

  // Update with phases
  await stripe.subscriptionSchedules.update(schedule.id, {
    phases: [
      // Current phase until period end
      {
        items: [{
          price: subscription.stripe_price_id,
          quantity: 1
        }],
        start_date: stripeSubscription.current_period_start,
        end_date: stripeSubscription.current_period_end,
      },
      // New phase starting at renewal
      {
        items: [{
          price: change.priceId!,
          quantity: 1
        }],
        start_date: stripeSubscription.current_period_end,
      }
    ],
    metadata: {
      ffm_scheduled_change: '1',
      ffm_target_plan: change.planId,
      ffm_target_interval: change.interval,
      ffm_reason: change.reason || 'unknown'
    }
  })

  return {
    scheduleId: schedule.id,
    effectiveAt: new Date(stripeSubscription.current_period_end * 1000).toISOString()
  }
}
```

### Cancel Scheduled Changes

```typescript
export async function cancelExistingScheduledChange(
  subscription: any
): Promise<{ success: boolean; cancelledSchedule?: boolean; cancelledFlag?: boolean }> {
  
  console.log('🚫 Cancelling existing scheduled change')
  
  try {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    let cancelledSchedule = false
    let cancelledFlag = false

    // Step 1: Try to cancel any active subscription schedules
    try {
      const schedules = await stripe.subscriptionSchedules.list({
        subscription: subscription.stripe_subscription_id,
        limit: 10
      })

      for (const schedule of schedules.data) {
        if (schedule.status === 'active') {
          await stripe.subscriptionSchedules.cancel(schedule.id)
          cancelledSchedule = true
          console.log(`✅ Cancelled subscription schedule: ${schedule.id}`)
        }
      }
    } catch (error) {
      console.log('No active schedules found or cancellation failed:', error)
    }

    // Step 2: Clear cancel_at_period_end flag if set
    if (subscription.cancel_at_period_end) {
      await stripe.subscriptions.update(subscription.stripe_subscription_id, {
        cancel_at_period_end: false
      })
      cancelledFlag = true
      console.log('✅ Cleared cancel_at_period_end flag')
    }

    // Step 3: Clear scheduled_change metadata
    const supabase = createServerServiceRoleClient()
    const currentMetadata = (subscription.metadata || {}) as SubscriptionMetadata
    
    if (currentMetadata.scheduled_change) {
      const { 
        scheduled_change, 
        upgrade_context, 
        downgrade_context, 
        ...remainingMetadata 
      } = currentMetadata

      await supabase
        .from('subscriptions')
        .update({
          cancel_at_period_end: false,
          metadata: {
            ...remainingMetadata,
            cancellation_history: [
              ...(remainingMetadata.cancellation_history || []),
              {
                cancelled_change: scheduled_change,
                cancelled_at: new Date().toISOString(),
                reason: 'user_requested'
              }
            ]
          },
          updated_at: new Date().toISOString()
        })
        .eq('id', subscription.id)

      console.log('✅ Cleared scheduled_change metadata')
    }

    return { 
      success: true, 
      cancelledSchedule, 
      cancelledFlag 
    }

  } catch (error) {
    console.error('❌ Error cancelling scheduled change:', error)
    return { success: false }
  }
}
```

## UI State Management

### Scheduled Change Display Hook

```typescript
// hooks/useScheduledChange.ts
import { useState, useEffect } from 'react'
import { useAuth } from './useAuth'

export interface ScheduledChangeDisplay {
  hasScheduledChange: boolean
  scheduledChange?: ScheduledChange
  displayText?: string
  effectiveDate?: string
  canCancel?: boolean
  changeType?: 'upgrade' | 'downgrade' | 'interval_change'
}

export function useScheduledChange(): {
  scheduledChange: ScheduledChangeDisplay
  loading: boolean
  cancelScheduledChange: () => Promise<void>
  reload: () => Promise<void>
} {
  const [scheduledChange, setScheduledChange] = useState<ScheduledChangeDisplay>({
    hasScheduledChange: false
  })
  const [loading, setLoading] = useState(true)
  const { user } = useAuth()

  useEffect(() => {
    if (user) {
      loadScheduledChange()
    }
  }, [user])

  const loadScheduledChange = async () => {
    if (!user) return

    setLoading(true)
    try {
      const subscription = await getSubscriptionDetails(user.id)
      
      if (!subscription) {
        setScheduledChange({ hasScheduledChange: false })
        return
      }

      // Check for scheduled change in metadata
      const metadata = subscription.metadata as SubscriptionMetadata
      const scheduledChangeData = metadata?.scheduled_change

      // Also check cancel_at_period_end flag
      const hasCancelFlag = subscription.cancel_at_period_end

      if (scheduledChangeData || hasCancelFlag) {
        const effectiveDate = scheduledChangeData?.effectiveAt || subscription.current_period_end
        const targetPlan = scheduledChangeData?.planId || 'free'
        const targetInterval = scheduledChangeData?.interval || 'month'

        const displayText = formatScheduledChangeDisplay(
          subscription.plan_id,
          targetPlan,
          targetInterval,
          effectiveDate
        )

        setScheduledChange({
          hasScheduledChange: true,
          scheduledChange: scheduledChangeData,
          displayText,
          effectiveDate,
          canCancel: true,
          changeType: determineChangeType(subscription.plan_id, targetPlan, targetInterval)
        })
      } else {
        setScheduledChange({ hasScheduledChange: false })
      }

    } catch (error) {
      console.error('Failed to load scheduled change:', error)
      setScheduledChange({ hasScheduledChange: false })
    } finally {
      setLoading(false)
    }
  }

  const cancelScheduledChange = async () => {
    try {
      const response = await fetch('/api/billing/cancel-plan-change', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' }
      })

      if (!response.ok) {
        throw new Error('Failed to cancel scheduled change')
      }

      await loadScheduledChange() // Reload state
    } catch (error) {
      console.error('Failed to cancel scheduled change:', error)
      throw error
    }
  }

  return {
    scheduledChange,
    loading,
    cancelScheduledChange,
    reload: loadScheduledChange
  }
}

function formatScheduledChangeDisplay(
  currentPlan: string,
  targetPlan: string,
  targetInterval: 'month' | 'year',
  effectiveDate: string
): string {
  const date = new Date(effectiveDate).toLocaleDateString()
  const targetPrice = getPlanPrice(targetPlan, targetInterval)
  const priceDisplay = targetPrice === 0 ? 'Free' : `$${(targetPrice / 100).toFixed(0)}/${targetInterval === 'month' ? 'mo' : 'yr'}`

  return `${currentPlan} until ${date}, then ${priceDisplay}`
}

function determineChangeType(
  currentPlan: string,
  targetPlan: string,
  targetInterval: string
): 'upgrade' | 'downgrade' | 'interval_change' {
  if (currentPlan === targetPlan) {
    return 'interval_change'
  }
  
  if (canUpgradeTo(currentPlan, targetPlan)) {
    return 'upgrade'
  }
  
  return 'downgrade'
}
```

### Scheduled Change Banner Component

```typescript
// components/billing/ScheduledChangeBanner.tsx
import { XMarkIcon, CalendarIcon } from '@heroicons/react/24/outline'
import { useScheduledChange } from '@/hooks/useScheduledChange'

export function ScheduledChangeBanner() {
  const { scheduledChange, cancelScheduledChange } = useScheduledChange()

  if (!scheduledChange.hasScheduledChange) {
    return null
  }

  const handleCancel = async () => {
    try {
      await cancelScheduledChange()
      // Show success message
    } catch (error) {
      // Show error message
      console.error('Failed to cancel:', error)
    }
  }

  const getBannerStyle = () => {
    switch (scheduledChange.changeType) {
      case 'upgrade':
        return 'bg-green-50 border-green-200 text-green-800'
      case 'downgrade':
        return 'bg-yellow-50 border-yellow-200 text-yellow-800'
      case 'interval_change':
        return 'bg-blue-50 border-blue-200 text-blue-800'
      default:
        return 'bg-gray-50 border-gray-200 text-gray-800'
    }
  }

  return (
    <div className={`border rounded-lg p-4 ${getBannerStyle()}`}>
      <div className="flex items-start">
        <CalendarIcon className="h-5 w-5 mt-0.5 mr-3" />
        
        <div className="flex-1">
          <h4 className="font-medium mb-1">
            Scheduled Plan Change
          </h4>
          <p className="text-sm">
            {scheduledChange.displayText}
          </p>
          
          {scheduledChange.scheduledChange?.reason && (
            <p className="text-xs mt-1 opacity-75">
              Reason: {scheduledChange.scheduledChange.reason.replace('_', ' ')}
            </p>
          )}
        </div>

        {scheduledChange.canCancel && (
          <button
            onClick={handleCancel}
            className="ml-3 text-sm underline hover:no-underline"
            title="Cancel scheduled change"
          >
            Cancel
          </button>
        )}
      </div>
    </div>
  )
}
```

## Complex Scheduling Scenarios

### Multiple Pending Changes

```typescript
// lib/multi-change-handler.ts
export async function handleMultiplePendingChanges(
  subscription: any,
  newChange: ScheduledChange
): Promise<{ action: string; message: string }> {
  
  const metadata = subscription.metadata as SubscriptionMetadata
  const existingChange = metadata?.scheduled_change

  if (!existingChange) {
    // No existing change, proceed normally
    return { action: 'create', message: 'Creating new scheduled change' }
  }

  // Analyze the conflict
  const conflict = analyzeScheduleConflict(existingChange, newChange)
  
  switch (conflict.resolution) {
    case 'replace':
      await cancelExistingScheduledChange(subscription)
      return { 
        action: 'replace', 
        message: `Cancelled previous change and scheduled new change` 
      }
    
    case 'merge':
      const mergedChange = mergeScheduledChanges(existingChange, newChange)
      return { 
        action: 'merge', 
        message: 'Updated existing scheduled change' 
      }
    
    case 'reject':
      return { 
        action: 'reject', 
        message: conflict.reason || 'Cannot schedule conflicting changes' 
      }
    
    default:
      return { 
        action: 'error', 
        message: 'Unable to resolve scheduling conflict' 
      }
  }
}

function analyzeScheduleConflict(
  existing: ScheduledChange,
  proposed: ScheduledChange
): { resolution: 'replace' | 'merge' | 'reject'; reason?: string } {
  
  // Same target plan and interval - no conflict
  if (existing.planId === proposed.planId && existing.interval === proposed.interval) {
    return { resolution: 'merge' }
  }

  // Different effective dates - replace existing
  if (existing.effectiveAt !== proposed.effectiveAt) {
    return { resolution: 'replace' }
  }

  // Conflicting changes - require user decision
  return { 
    resolution: 'reject', 
    reason: 'You already have a scheduled plan change. Cancel it first to make a new change.' 
  }
}

function mergeScheduledChanges(
  existing: ScheduledChange,
  proposed: ScheduledChange
): ScheduledChange {
  return {
    ...existing,
    ...proposed,
    context: {
      ...existing.context,
      ...proposed.context,
      merged_at: new Date().toISOString()
    }
  }
}
```

### Schedule Conflict Resolution API

```typescript
// billing/resolve-schedule-conflict.ts - Framework-agnostic conflict resolution
export async function handleScheduleConflictResolution(request: Request): Promise<Response> {
  try {
    // Extract user context (implementation varies by framework)
    const user = await getUserFromRequest(request)
    if (!user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const { action, newPlanId, billingInterval } = await request.json()

    // Get current subscription
    const { data: subscription, error: subError } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('user_id', user.id)
      .single()

    if (subError || !subscription) {
      return new Response(
        JSON.stringify({ error: 'No subscription found' }),
        { status: 404, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const metadata = subscription.metadata as SubscriptionMetadata
    const existingChange = metadata?.scheduled_change

    if (!existingChange) {
      return new Response(
        JSON.stringify({ error: 'No scheduled change to resolve' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    switch (action) {
      case 'cancel_and_proceed':
        await cancelExistingScheduledChange(subscription)
        return new Response(
          JSON.stringify({
            success: true,
            message: 'Previous scheduled change cancelled. You can now make a new change.',
            action: 'proceed_with_new_change'
          }),
          { headers: { 'Content-Type': 'application/json' } }
        )

      case 'keep_existing':
        return new Response(
          JSON.stringify({
            success: true,
            message: 'Keeping existing scheduled change.',
            existingChange,
            action: 'keep_existing'
          }),
          { headers: { 'Content-Type': 'application/json' } }
        )

      case 'replace':
        const result = await handleMultiplePendingChanges(subscription, {
          planId: newPlanId,
          interval: billingInterval,
          priceId: getStripePriceId(newPlanId, billingInterval),
          reason: 'user_change'
        })
        
        return new Response(
          JSON.stringify({
            success: true,
            message: result.message,
            action: result.action
          }),
          { headers: { 'Content-Type': 'application/json' } }
        )

      default:
        return new Response(
          JSON.stringify({ error: 'Invalid action' }),
          { status: 400, headers: { 'Content-Type': 'application/json' } }
        )
    }

  } catch (error) {
    console.error('Schedule conflict resolution error:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to resolve conflict' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

## Testing Scheduled Changes

### Unit Tests

```typescript
// __tests__/lib/scheduled-change-manager.test.ts
import { createScheduledChange, cancelExistingScheduledChange } from '@/lib/scheduled-change-manager'

describe('Scheduled Change Manager', () => {
  it('should create scheduled change with subscription schedule', async () => {
    const mockSubscription = {
      id: 'sub_123',
      stripe_subscription_id: 'sub_stripe_123',
      plan_id: 'starter',
      metadata: {}
    }

    const change = {
      planId: 'pro',
      interval: 'month' as const,
      priceId: 'price_pro_monthly',
      reason: 'upgrade' as const
    }

    const result = await createScheduledChange(mockSubscription.id, change, {
      useSchedule: true
    })

    expect(result.success).toBe(true)
    expect(result.scheduleId).toBeDefined()
  })

  it('should cancel existing scheduled changes', async () => {
    const mockSubscription = {
      stripe_subscription_id: 'sub_stripe_123',
      cancel_at_period_end: true,
      metadata: {
        scheduled_change: {
          planId: 'free',
          interval: 'month',
          priceId: 'price_free',
          effectiveAt: '2024-02-01T00:00:00Z'
        }
      }
    }

    const result = await cancelExistingScheduledChange(mockSubscription)

    expect(result.success).toBe(true)
    expect(result.cancelledFlag).toBe(true)
  })
})
```

### E2E Tests

```typescript
// cypress/e2e/billing/scheduled-changes.cy.ts
describe('Scheduled Changes Management', () => {
  describe('Cancel-First Flow', () => {
    const email = `scheduled-change-${Date.now()}@example.com`

    beforeEach(() => {
      cy.seedStarterUserWithScheduledDowngrade({ email })
      cy.login(email)
    })

    it('should show cancel-first modal when user has existing scheduled change', () => {
      cy.visit('/billing')

      // Should show scheduled change banner
      cy.get('[data-testid="scheduled-change-banner"]').should('be.visible')
      cy.get('[data-testid="scheduled-change-banner"]').should('contain', 'until')

      // Try to make another change
      cy.get('[data-testid="pro-action-button"]').click()

      // Should show cancel-first modal
      cy.get('[data-testid="cancel-first-modal"]').should('be.visible')
      cy.get('[data-testid="cancel-first-modal"]').should('contain', 'existing scheduled change')

      // Cancel existing change
      cy.intercept('POST', '/api/billing/cancel-plan-change').as('cancelChange')
      cy.get('[data-testid="cancel-existing-change"]').click()

      cy.wait('@cancelChange').then((interception) => {
        expect(interception.response?.statusCode).to.eq(200)
      })

      // Should proceed to upgrade modal
      cy.get('[data-testid="upgrade-confirmation-modal"]').should('be.visible')
    })

    it('should allow keeping existing scheduled change', () => {
      cy.visit('/billing')

      // Try to make another change
      cy.get('[data-testid="pro-action-button"]').click()

      // Should show cancel-first modal
      cy.get('[data-testid="cancel-first-modal"]').should('be.visible')

      // Keep existing change
      cy.get('[data-testid="keep-existing-change"]').click()

      // Modal should close, no changes made
      cy.get('[data-testid="cancel-first-modal"]').should('not.exist')
      cy.get('[data-testid="scheduled-change-banner"]').should('be.visible')
    })
  })

  describe('Schedule Lifecycle', () => {
    it('should clear scheduled change when schedule enters phase 2', () => {
      const email = `schedule-lifecycle-${Date.now()}@example.com`
      
      cy.seedStarterUserWithScheduledDowngrade({ email })
      cy.login(email)
      cy.visit('/billing')

      // Should show scheduled change
      cy.get('[data-testid="scheduled-change-banner"]').should('be.visible')

      // Simulate schedule entering phase 2
      cy.task('simulateSubscriptionScheduleUpdated', { email }).then((result: any) => {
        expect(result.ok).to.be.true
      })

      // Reload and verify banner is gone
      cy.reload()
      cy.get('[data-testid="scheduled-change-banner"]').should('not.exist')
    })
  })
})
```

## Next Steps

In the next module, we'll cover implementing annual billing with proper discounting and the considerations for annual subscription management.

## Key Takeaways

- Use subscription metadata to store scheduled change information
- Implement cancel-first flow for conflicting scheduled changes
- Handle multiple types of scheduled changes (downgrades, interval changes, cancellations)
- Use Stripe subscription schedules for complex timing requirements
- Provide clear UI feedback about pending changes
- Handle schedule conflicts with user-friendly resolution options
- Test scheduled change scenarios thoroughly
- Coordinate between Stripe schedules and database state
- Implement proper cancellation and cleanup logic
- Use webhooks to clear scheduled changes when they become active
