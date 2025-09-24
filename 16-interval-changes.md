# Monthly ↔ Annual Billing Interval Changes

## Overview

This module covers implementing billing interval changes between monthly and annual billing. Based on your codebase analysis, interval changes are among the most complex scenarios in Stripe billing, requiring subscription schedules and careful timing management.

## Interval Change Complexity

Your codebase handles interval changes with sophisticated logic:

### Why Interval Changes Are Complex

1. **Stripe Limitation**: Cannot change billing interval mid-cycle with simple subscription update
2. **Billing Anchor**: Changing intervals affects the billing cycle anchor date
3. **Proration Issues**: Interval changes create complex proration scenarios
4. **User Experience**: Need to preserve current billing period value

### Your Codebase's Approach

From your `docs/stripe-upgrades-downgrades.md`:

```
- Monthly → Annual: treat as an upgrade now (immediate, prorated)
- Annual → Monthly: defer to next period (requires Subscription Schedule)
```

## Monthly to Annual Changes (Upgrade Pattern)

### Implementation Logic

```typescript
// lib/interval-changes.ts
export async function handleMonthlyToAnnualChange(
  stripe: Stripe,
  supabase: any,
  subscription: any,
  planId: string
): Promise<any> {
  console.log('📅 Processing Monthly → Annual interval change')

  try {
    // Get annual price for the same plan
    const annualPriceId = getStripePriceId(planId, 'year')
    if (!annualPriceId) {
      throw new Error(`No annual pricing available for ${planId}`)
    }

    // This is treated as an immediate upgrade with proration
    const stripeSubscription = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
    const subscriptionItemId = stripeSubscription.items.data[0].id

    // Update subscription to annual price immediately
    const updatedSubscription = await stripe.subscriptions.update(subscription.stripe_subscription_id, {
      items: [{
        id: subscriptionItemId,
        price: annualPriceId,
      }],
      proration_behavior: 'create_prorations',
    })

    // Update database
    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        stripe_price_id: annualPriceId,
        status: updatedSubscription.status,
        current_period_start: new Date(updatedSubscription.current_period_start * 1000).toISOString(),
        current_period_end: new Date(updatedSubscription.current_period_end * 1000).toISOString(),
        metadata: {
          interval_change: {
            from: 'month',
            to: 'year',
            changed_at: new Date().toISOString(),
            type: 'immediate_upgrade'
          }
        },
        updated_at: new Date().toISOString()
      })
      .eq('id', subscription.id)
      .select()
      .single()

    if (error) {
      console.error('❌ Database update failed:', error)
      throw error
    }

    console.log('✅ Monthly → Annual change completed immediately')
    return {
      success: true,
      type: 'immediate',
      subscription: data,
      message: `Switched to annual billing. You'll save money on your next renewal!`
    }

  } catch (error) {
    console.error('❌ Monthly → Annual change failed:', error)
    throw error
  }
}
```

## Annual to Monthly Changes (Schedule Pattern)

### Implementation with Subscription Schedules

```typescript
export async function handleAnnualToMonthlyChange(
  stripe: Stripe,
  supabase: any,
  subscription: any,
  planId: string
): Promise<any> {
  console.log('📅 Processing Annual → Monthly interval change (scheduled)')

  try {
    // Get monthly price for the same plan
    const monthlyPriceId = getStripePriceId(planId, 'month')
    if (!monthlyPriceId) {
      throw new Error(`No monthly pricing available for ${planId}`)
    }

    // Get current subscription details
    const stripeSubscription = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)

    // Step 1: Create subscription schedule from current subscription
    const schedule = await stripe.subscriptionSchedules.create({
      from_subscription: subscription.stripe_subscription_id,
    })

    console.log('✅ Created subscription schedule:', schedule.id)

    // Step 2: Update schedule with two phases
    await stripe.subscriptionSchedules.update(schedule.id, {
      phases: [
        // Phase 1: Current annual plan until period end
        {
          items: [{
            price: subscription.stripe_price_id,
            quantity: 1
          }],
          start_date: stripeSubscription.current_period_start,
          end_date: stripeSubscription.current_period_end,
        },
        // Phase 2: Monthly plan starting at renewal
        {
          items: [{
            price: monthlyPriceId,
            quantity: 1
          }],
          start_date: stripeSubscription.current_period_end,
        }
      ],
      metadata: {
        ffm_interval_switch: '1',
        ffm_target_interval: 'month',
        ffm_original_interval: 'year',
        ffm_plan_id: planId
      }
    })

    console.log('✅ Updated schedule with monthly phase')

    // Step 3: Update database with scheduled change
    const scheduledChange = {
      planId: planId,
      interval: 'month' as const,
      priceId: monthlyPriceId,
      effectiveAt: new Date(stripeSubscription.current_period_end * 1000).toISOString(),
    }

    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        cancel_at_period_end: false, // Important: don't set this for schedule-based changes
        metadata: {
          scheduled_change: scheduledChange,
          interval_change_context: {
            from: 'year',
            to: 'month',
            schedule_id: schedule.id,
            scheduled_at: new Date().toISOString(),
            type: 'scheduled_downgrade'
          }
        },
        updated_at: new Date().toISOString()
      })
      .eq('id', subscription.id)
      .select()
      .single()

    if (error) {
      console.error('❌ Database update failed:', error)
      throw error
    }

    console.log('✅ Annual → Monthly change scheduled')
    return {
      success: true,
      type: 'scheduled',
      subscription: data,
      scheduledChange,
      scheduleId: schedule.id,
      message: `Billing will switch to monthly at the end of your current annual period`
    }

  } catch (error) {
    console.error('❌ Annual → Monthly change failed:', error)
    throw error
  }
}
```

## Cross-Plan Interval Changes

Your codebase handles complex scenarios like "Pro Annual → Scale Monthly":

### Complex Interval Change Logic

```typescript
// lib/complex-interval-changes.ts
export async function handleCrossPlanIntervalChange(
  stripe: Stripe,
  supabase: any,
  subscription: any,
  newPlanId: string,
  newInterval: 'month' | 'year'
): Promise<any> {
  console.log(`🔄 Processing cross-plan interval change: ${subscription.plan_id} → ${newPlanId} (${newInterval})`)

  const currentInterval = getBillingIntervalFromPrice(subscription.stripe_price_id)
  const isUpgrade = canUpgradeTo(subscription.plan_id, newPlanId)

  if (isUpgrade && newInterval === 'month' && currentInterval === 'year') {
    // Special case: Pro Annual → Scale Monthly
    // Step 1: Upgrade to Scale Annual immediately (for benefits)
    // Step 2: Schedule interval switch to monthly at renewal
    return await handleUpgradeWithIntervalSwitch(
      stripe,
      supabase,
      subscription,
      newPlanId,
      newInterval
    )
  }

  if (!isUpgrade && newInterval !== currentInterval) {
    // Downgrade with interval change - use schedule
    return await handleDowngradeWithIntervalSwitch(
      stripe,
      supabase,
      subscription,
      newPlanId,
      newInterval
    )
  }

  throw new Error('Unsupported cross-plan interval change scenario')
}

async function handleUpgradeWithIntervalSwitch(
  stripe: Stripe,
  supabase: any,
  subscription: any,
  newPlanId: string,
  targetInterval: 'month' | 'year'
) {
  console.log('🚀 Upgrade now + schedule interval switch')

  // Step 1: Upgrade to new plan's annual price immediately
  const newAnnualPriceId = getStripePriceId(newPlanId, 'year')
  if (!newAnnualPriceId) {
    throw new Error(`No annual price for ${newPlanId}`)
  }

  const stripeSubscription = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
  const subscriptionItemId = stripeSubscription.items.data[0].id

  // Immediate upgrade with proration
  const upgradedSubscription = await stripe.subscriptions.update(subscription.stripe_subscription_id, {
    items: [{
      id: subscriptionItemId,
      price: newAnnualPriceId,
    }],
    proration_behavior: 'create_prorations',
  })

  // Step 2: Create schedule for interval switch
  const monthlyPriceId = getStripePriceId(newPlanId, 'month')
  if (!monthlyPriceId) {
    throw new Error(`No monthly price for ${newPlanId}`)
  }

  const schedule = await stripe.subscriptionSchedules.create({
    from_subscription: subscription.stripe_subscription_id,
  })

  await stripe.subscriptionSchedules.update(schedule.id, {
    phases: [
      {
        items: [{ price: newAnnualPriceId, quantity: 1 }],
        start_date: upgradedSubscription.current_period_start,
        end_date: upgradedSubscription.current_period_end,
      },
      {
        items: [{ price: monthlyPriceId, quantity: 1 }],
        start_date: upgradedSubscription.current_period_end,
      }
    ],
    metadata: {
      ffm_interval_switch: '1',
      ffm_target_interval: targetInterval,
      ffm_upgrade_context: '1'
    }
  })

  // Step 3: Update database
  const scheduledChange = {
    planId: newPlanId,
    interval: targetInterval,
    priceId: monthlyPriceId,
    effectiveAt: new Date(upgradedSubscription.current_period_end * 1000).toISOString(),
  }

  const { data, error } = await supabase
    .from('subscriptions')
    .update({
      stripe_price_id: newAnnualPriceId, // Currently on annual
      plan_id: newPlanId, // New plan active immediately
      status: upgradedSubscription.status,
      current_period_start: new Date(upgradedSubscription.current_period_start * 1000).toISOString(),
      current_period_end: new Date(upgradedSubscription.current_period_end * 1000).toISOString(),
      cancel_at_period_end: false,
      metadata: {
        scheduled_change: scheduledChange,
        upgrade_context: {
          original_plan: subscription.plan_id,
          original_interval: 'year',
          upgrade_type: 'plan_and_interval',
          schedule_id: schedule.id
        }
      },
      updated_at: new Date().toISOString()
    })
    .eq('id', subscription.id)
    .select()
    .single()

  if (error) {
    throw error
  }

  return {
    success: true,
    type: 'upgrade_with_interval_switch',
    subscription: data,
    scheduledChange,
    message: `Upgraded to ${newPlanId} immediately. Billing will switch to monthly at renewal.`
  }
}
```

## Frontend Interval Change Components

### Interval Change Modal

```typescript
// components/billing/IntervalChangeModal.tsx
import { useState, useEffect } from 'react'
import { useProrationPreview } from '@/hooks/useProrationPreview'

interface IntervalChangeModalProps {
  isOpen: boolean
  onClose: () => void
  currentPlan: string
  currentInterval: 'month' | 'year'
  targetInterval: 'month' | 'year'
  onConfirm: () => Promise<void>
}

export function IntervalChangeModal({
  isOpen,
  onClose,
  currentPlan,
  currentInterval,
  targetInterval,
  onConfirm
}: IntervalChangeModalProps) {
  const [confirming, setConfirming] = useState(false)
  const { preview, loading, calculatePreview } = useProrationPreview()

  useEffect(() => {
    if (isOpen) {
      const targetPriceId = getStripePriceId(currentPlan, targetInterval)
      if (targetPriceId) {
        calculatePreview({
          newPriceId: targetPriceId,
          billingInterval: targetInterval
        })
      }
    }
  }, [isOpen, currentPlan, targetInterval])

  const handleConfirm = async () => {
    setConfirming(true)
    try {
      await onConfirm()
      onClose()
    } catch (error) {
      console.error('Interval change failed:', error)
    } finally {
      setConfirming(false)
    }
  }

  if (!isOpen) return null

  const isUpgrade = targetInterval === 'year'
  const changeType = isUpgrade ? 'upgrade' : 'downgrade'

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg p-6 max-w-lg w-full mx-4">
        <h3 className="text-lg font-semibold mb-4">
          Switch to {targetInterval === 'year' ? 'Annual' : 'Monthly'} Billing
        </h3>

        <div className="mb-6">
          <p className="text-gray-600 mb-4">
            You're switching from <strong>{currentInterval}ly</strong> to <strong>{targetInterval}ly</strong> billing 
            for your <strong>{currentPlan}</strong> plan.
          </p>

          {isUpgrade ? (
            <div className="bg-green-50 border border-green-200 rounded-md p-4">
              <h4 className="text-sm font-medium text-green-800 mb-2">
                Immediate Upgrade to Annual
              </h4>
              <ul className="text-sm text-green-700 space-y-1">
                <li>• Upgrade takes effect immediately</li>
                <li>• You'll save money with annual billing</li>
                <li>• Proration applies for the current period</li>
                <li>• Next renewal will be in 12 months</li>
              </ul>
            </div>
          ) : (
            <div className="bg-blue-50 border border-blue-200 rounded-md p-4">
              <h4 className="text-sm font-medium text-blue-800 mb-2">
                Scheduled Switch to Monthly
              </h4>
              <ul className="text-sm text-blue-700 space-y-1">
                <li>• Change takes effect at end of current annual period</li>
                <li>• You'll keep your annual plan until then</li>
                <li>• No immediate charges or credits</li>
                <li>• Next billing will be monthly</li>
              </ul>
            </div>
          )}
        </div>

        {/* Proration Preview */}
        {loading ? (
          <div className="mb-6 p-4 bg-gray-50 rounded">
            <p className="text-sm text-gray-600">Calculating billing changes...</p>
          </div>
        ) : preview && isUpgrade ? (
          <div className="mb-6 p-4 bg-gray-50 rounded">
            <h4 className="font-medium mb-2">Billing Summary</h4>
            <div className="flex justify-between text-sm">
              <span>Due today (prorated):</span>
              <span className="font-medium">${preview.amountDue.toFixed(2)}</span>
            </div>
            {preview.nextInvoicePreview && (
              <div className="flex justify-between text-sm mt-1 text-gray-600">
                <span>Next annual renewal:</span>
                <span>${preview.nextInvoicePreview.amount.toFixed(2)}</span>
              </div>
            )}
          </div>
        ) : !isUpgrade ? (
          <div className="mb-6 p-4 bg-gray-50 rounded">
            <h4 className="font-medium mb-2">No Immediate Charges</h4>
            <p className="text-sm text-gray-600">
              This change is scheduled for the end of your current billing period. 
              No charges will be made today.
            </p>
          </div>
        ) : null}

        <div className="flex space-x-3">
          <button
            onClick={onClose}
            disabled={confirming}
            className="flex-1 px-4 py-2 border border-gray-300 rounded-md text-gray-700 hover:bg-gray-50 disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            onClick={handleConfirm}
            disabled={confirming}
            className="flex-1 px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 disabled:opacity-50"
          >
            {confirming ? 'Processing...' : `Switch to ${targetInterval === 'year' ? 'Annual' : 'Monthly'}`}
          </button>
        </div>
      </div>
    </div>
  )
}
```

### Billing Interval Toggle with Smart Detection

```typescript
// components/billing/SmartBillingToggle.tsx
import { useState } from 'react'
import { useCurrentPlan } from '@/hooks/useCurrentPlan'
import { IntervalChangeModal } from './IntervalChangeModal'

interface SmartBillingToggleProps {
  currentInterval: 'month' | 'year'
  onIntervalChange: (interval: 'month' | 'year') => void
  disabled?: boolean
}

export function SmartBillingToggle({
  currentInterval,
  onIntervalChange,
  disabled = false
}: SmartBillingToggleProps) {
  const [showModal, setShowModal] = useState(false)
  const [pendingInterval, setPendingInterval] = useState<'month' | 'year' | null>(null)
  const { currentPlan } = useCurrentPlan()

  const handleIntervalClick = (newInterval: 'month' | 'year') => {
    if (disabled || newInterval === currentInterval) return

    // Check if user has an active subscription
    if (currentPlan && currentPlan !== 'free') {
      // Show confirmation modal for subscription changes
      setPendingInterval(newInterval)
      setShowModal(true)
    } else {
      // No subscription, just change the display
      onIntervalChange(newInterval)
    }
  }

  const handleConfirmIntervalChange = async () => {
    if (!pendingInterval || !currentPlan) return

    try {
      // Call appropriate API based on change type
      const isUpgrade = pendingInterval === 'year'
      const endpoint = isUpgrade ? '/api/billing/upgrade' : '/api/billing/downgrade'

      const response = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          newPlanId: currentPlan,
          billingInterval: pendingInterval
        })
      })

      if (!response.ok) {
        throw new Error('Interval change failed')
      }

      // Update UI
      onIntervalChange(pendingInterval)
      
      // Show success message
      const changeType = pendingInterval === 'year' ? 'annual' : 'monthly'
      const message = isUpgrade 
        ? `Switched to ${changeType} billing immediately`
        : `Scheduled switch to ${changeType} billing`
      
      // You'd show this via toast or notification system
      console.log(message)

    } catch (error) {
      console.error('Interval change failed:', error)
      throw error
    }
  }

  return (
    <div className="relative bg-gray-100 rounded-lg p-1 flex">
      <button
        onClick={() => handleIntervalClick('month')}
        disabled={disabled}
        className={`relative px-4 py-2 text-sm font-medium rounded-md transition-all ${
          currentInterval === 'month'
            ? 'bg-white text-gray-900 shadow-sm'
            : 'text-gray-600 hover:text-gray-900'
        } ${disabled ? 'opacity-50 cursor-not-allowed' : ''}`}
      >
        Monthly
      </button>
      
      <button
        onClick={() => handleIntervalClick('year')}
        disabled={disabled}
        className={`relative px-4 py-2 text-sm font-medium rounded-md transition-all ${
          currentInterval === 'year'
            ? 'bg-white text-gray-900 shadow-sm'
            : 'text-gray-600 hover:text-gray-900'
        } ${disabled ? 'opacity-50 cursor-not-allowed' : ''}`}
      >
        <span>Annual</span>
        <span className="ml-1 text-xs text-green-600 font-semibold">
          Save 20%
        </span>
      </button>

      {/* Interval Change Modal */}
      {showModal && pendingInterval && currentPlan && (
        <IntervalChangeModal
          isOpen={showModal}
          onClose={() => {
            setShowModal(false)
            setPendingInterval(null)
          }}
          currentPlan={currentPlan}
          currentInterval={currentInterval}
          targetInterval={pendingInterval}
          onConfirm={handleConfirmIntervalChange}
        />
      )}
    </div>
  )
}
```

## Webhook Handling for Interval Changes

### Schedule Event Handlers

Your codebase includes sophisticated webhook handlers for schedule events:

```typescript
// Enhanced handlers for interval changes
export async function handleSubscriptionScheduleUpdated(schedule: any) {
  console.log('📅 Processing subscription_schedule.updated for interval change')
  
  try {
    const subscriptionId = schedule.subscription
    const phases = schedule?.phases || []
    const currentPhaseStart = schedule?.current_phase?.start_date

    if (!subscriptionId || !phases.length || !currentPhaseStart) {
      return
    }

    const currentIndex = phases.findIndex(p => p?.start_date === currentPhaseStart)
    
    // When entering phase 2 (target interval), clear scheduled change metadata
    if (currentIndex >= 1) {
      const supabase = createServerServiceRoleClient()
      
      const { data: row, error: readErr } = await supabase
        .from('subscriptions')
        .select('id, metadata, plan_id')
        .eq('stripe_subscription_id', subscriptionId)
        .single()
        
      if (readErr) {
        console.error('❌ Error reading subscription:', readErr)
        return
      }

      const currentMeta = (row?.metadata || {}) as Record<string, any>
      
      if (currentMeta && 'scheduled_change' in currentMeta) {
        const { scheduled_change, interval_change_context, ...remainingMetadata } = currentMeta

        // Update to reflect the interval change is now active
        const { error: updErr } = await supabase
          .from('subscriptions')
          .update({ 
            metadata: {
              ...remainingMetadata,
              interval_change_history: {
                completed_at: new Date().toISOString(),
                from_interval: interval_change_context?.from || 'unknown',
                to_interval: scheduled_change?.interval || 'unknown',
                plan_id: row.plan_id
              }
            },
            updated_at: new Date().toISOString()
          })
          .eq('id', row!.id)
          
        if (updErr) {
          console.error('❌ Error clearing scheduled_change metadata:', updErr)
          return
        }
        
        console.log(`✅ Interval change completed for subscription ${subscriptionId}`)
        console.log(`Switched to ${scheduled_change?.interval || 'unknown'} billing`)
      }
    }
  } catch (error) {
    console.error('❌ Exception in handleSubscriptionScheduleUpdated:', error)
  }
}
```

## Testing Interval Changes

### E2E Tests for Interval Changes

```typescript
// cypress/e2e/billing/interval-changes.cy.ts
describe('Billing Interval Changes', () => {
  describe('Monthly to Annual (Immediate Upgrade)', () => {
    const email = `monthly-to-annual-${Date.now()}@example.com`

    beforeEach(() => {
      cy.seedStarterUser({ email })
      cy.login(email)
    })

    it('should upgrade to annual billing immediately with proration', () => {
      cy.visit('/billing')

      // Should start on monthly
      cy.get('[data-testid="current-plan-interval"]').should('contain', 'month')

      // Switch to annual view
      cy.get('[data-testid="billing-interval-annual"]').click()

      // Should show interval change modal
      cy.get('[data-testid="interval-change-modal"]').should('be.visible')
      cy.get('[data-testid="interval-change-type"]').should('contain', 'Immediate Upgrade')

      // Should show proration preview
      cy.get('[data-testid="proration-preview"]').should('be.visible')
      cy.get('[data-testid="amount-due"]').should('contain', '$')

      // Confirm change
      cy.intercept('POST', '/api/billing/upgrade').as('intervalUpgrade')
      cy.get('[data-testid="confirm-interval-change"]').click()

      cy.wait('@intervalUpgrade').then((interception) => {
        expect(interception.response?.statusCode).to.eq(200)
      })

      // Should show success and update UI
      cy.get('[data-testid="interval-change-success"]').should('be.visible')
      cy.reload()
      cy.get('[data-testid="current-plan-interval"]').should('contain', 'year')
    })
  })

  describe('Annual to Monthly (Scheduled Change)', () => {
    const email = `annual-to-monthly-${Date.now()}@example.com`

    beforeEach(() => {
      cy.seedStarterAnnualUser({ email })
      cy.login(email)
    })

    it('should schedule switch to monthly at end of period', () => {
      cy.visit('/billing')

      // Should start on annual
      cy.get('[data-testid="current-plan-interval"]').should('contain', 'year')

      // Switch to monthly view
      cy.get('[data-testid="billing-interval-monthly"]').click()

      // Should show interval change modal
      cy.get('[data-testid="interval-change-modal"]').should('be.visible')
      cy.get('[data-testid="interval-change-type"]').should('contain', 'Scheduled Switch')

      // Should show no immediate charges
      cy.get('[data-testid="no-immediate-charges"]').should('be.visible')

      // Confirm change
      cy.intercept('POST', '/api/billing/downgrade').as('intervalDowngrade')
      cy.get('[data-testid="confirm-interval-change"]').click()

      cy.wait('@intervalDowngrade').then((interception) => {
        expect(interception.response?.statusCode).to.eq(200)
      })

      // Should show scheduled change banner
      cy.get('[data-testid="scheduled-change-banner"]').should('be.visible')
      cy.get('[data-testid="scheduled-change-banner"]').should('contain', 'monthly')

      // Verify subscription schedule was created
      cy.task('getSubscriptionScheduleForEmail', { email }).then((res: any) => {
        expect(res.ok).to.be.true
        expect(res.scheduleId).to.be.a('string')
      })
    })
  })
})
```

## Interval Change Utilities

### Helper Functions

```typescript
// lib/interval-utils.ts
export function calculateAnnualSavings(planId: string): {
  monthlyTotal: number
  annualPrice: number
  savings: number
  savingsPercent: number
} | null {
  const monthlyPrice = getPlanPrice(planId, 'month')
  const annualPrice = getPlanPrice(planId, 'year')

  if (monthlyPrice === 0 || annualPrice === 0) return null

  const monthlyTotal = monthlyPrice * 12
  const savings = monthlyTotal - annualPrice
  const savingsPercent = Math.round((savings / monthlyTotal) * 100)

  return {
    monthlyTotal: monthlyTotal / 100,
    annualPrice: annualPrice / 100,
    savings: savings / 100,
    savingsPercent
  }
}

export function getIntervalChangeType(
  fromInterval: 'month' | 'year',
  toInterval: 'month' | 'year',
  planId: string
): 'upgrade' | 'downgrade' | 'invalid' {
  if (fromInterval === toInterval) return 'invalid'

  // Monthly to Annual is always an upgrade (immediate, saves money)
  if (fromInterval === 'month' && toInterval === 'year') {
    return 'upgrade'
  }

  // Annual to Monthly is always a downgrade (scheduled, loses savings)
  if (fromInterval === 'year' && toInterval === 'month') {
    return 'downgrade'
  }

  return 'invalid'
}

export function formatIntervalChangeMessage(
  fromInterval: 'month' | 'year',
  toInterval: 'month' | 'year',
  planId: string,
  effectiveDate?: string
): string {
  const changeType = getIntervalChangeType(fromInterval, toInterval, planId)
  const planConfig = getPlanConfig(planId)
  const planName = planConfig?.name || planId

  if (changeType === 'upgrade') {
    return `Switched to annual billing for ${planName}. You'll save money on future renewals!`
  }

  if (changeType === 'downgrade' && effectiveDate) {
    const date = new Date(effectiveDate).toLocaleDateString()
    return `Scheduled switch to monthly billing for ${planName} on ${date}`
  }

  return 'Billing interval updated'
}
```

## Next Steps

In the next module, we'll cover managing complex scheduled plan changes and how they interact with interval changes.

## Key Takeaways

- Monthly → Annual changes are immediate upgrades with proration
- Annual → Monthly changes require subscription schedules
- Use different UI patterns for immediate vs scheduled changes
- Implement proration previews for immediate changes
- Handle cross-plan interval changes with upgrade-then-schedule pattern
- Store interval change context in subscription metadata
- Test both upgrade and downgrade interval scenarios
- Provide clear messaging about when changes take effect
- Use subscription schedules for complex timing requirements
- Handle webhook events to clear scheduled changes when they activate
