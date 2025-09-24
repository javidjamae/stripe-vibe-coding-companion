# Mixed Upgrade Scenarios

## Overview

This module covers complex upgrade scenarios that involve both plan and interval changes, such as "Pro Annual → Scale Monthly". These scenarios require sophisticated logic combining immediate upgrades with scheduled interval switches.

## Mixed Upgrade Complexity

Based on your codebase analysis, mixed upgrades are the most complex billing scenarios:

### Why Mixed Upgrades Are Complex

1. **Immediate Benefits**: Users want higher plan features right away
2. **Interval Preference**: Users want different billing frequency
3. **Stripe Limitations**: Cannot change plan and interval simultaneously mid-cycle
4. **Billing Anchor**: Interval changes affect billing cycle timing
5. **User Experience**: Must be seamless despite technical complexity

### Your Codebase's Solution

From `docs/stripe-upgrades-downgrades.md`:

```
Annual → Monthly (higher plan):
1) Immediate upgrade now to the target plan's ANNUAL price (benefits are instant)
2) Create a Subscription Schedule from the existing subscription  
3) Add next phase that switches to the target plan's MONTHLY price at renewal
```

## Mixed Upgrade Implementation

### Detection Logic

```typescript
// lib/mixed-upgrade-detection.ts
export function isMixedUpgradeScenario(
  currentSubscription: any,
  targetPlanId: string,
  targetInterval: 'month' | 'year'
): boolean {
  const currentPlanId = currentSubscription.plan_id
  const currentInterval = getBillingIntervalFromPrice(currentSubscription.stripe_price_id)

  // Mixed upgrade criteria:
  // 1. Plan is changing AND interval is changing
  // 2. Plan change is an upgrade (higher tier)
  // 3. Interval change is typically annual → monthly

  const planChanging = currentPlanId !== targetPlanId
  const intervalChanging = currentInterval !== targetInterval
  const isUpgrade = canUpgradeTo(currentPlanId, targetPlanId)

  return planChanging && intervalChanging && isUpgrade
}

export function getMixedUpgradeStrategy(
  currentPlan: string,
  currentInterval: 'month' | 'year',
  targetPlan: string,
  targetInterval: 'month' | 'year'
): 'upgrade_now_schedule_interval' | 'schedule_both' | 'invalid' {
  
  if (!isMixedUpgradeScenario(
    { plan_id: currentPlan, stripe_price_id: getStripePriceId(currentPlan, currentInterval) },
    targetPlan,
    targetInterval
  )) {
    return 'invalid'
  }

  // For upgrades with interval change, prefer immediate upgrade + scheduled interval
  if (canUpgradeTo(currentPlan, targetPlan)) {
    return 'upgrade_now_schedule_interval'
  }

  // Fallback to scheduling both changes
  return 'schedule_both'
}
```

### Mixed Upgrade Handler

```typescript
// lib/mixed-upgrade-handler.ts
export async function handleMixedUpgrade(
  stripe: Stripe,
  supabase: any,
  subscription: any,
  targetPlanId: string,
  targetInterval: 'month' | 'year'
): Promise<any> {
  console.log(`🔀 Processing mixed upgrade: ${subscription.plan_id} → ${targetPlanId} (${targetInterval})`)

  const currentInterval = getBillingIntervalFromPrice(subscription.stripe_price_id)
  const strategy = getMixedUpgradeStrategy(
    subscription.plan_id,
    currentInterval,
    targetPlanId,
    targetInterval
  )

  switch (strategy) {
    case 'upgrade_now_schedule_interval':
      return await handleUpgradeNowScheduleInterval(
        stripe,
        supabase,
        subscription,
        targetPlanId,
        targetInterval
      )
    
    case 'schedule_both':
      return await handleScheduleBothChanges(
        stripe,
        supabase,
        subscription,
        targetPlanId,
        targetInterval
      )
    
    default:
      throw new Error('Invalid mixed upgrade scenario')
  }
}

async function handleUpgradeNowScheduleInterval(
  stripe: Stripe,
  supabase: any,
  subscription: any,
  targetPlanId: string,
  targetInterval: 'month' | 'year'
) {
  console.log('🚀 Strategy: Upgrade now + schedule interval change')

  try {
    // Step 1: Immediate upgrade to target plan's CURRENT interval price
    const currentInterval = getBillingIntervalFromPrice(subscription.stripe_price_id)
    const immediatePriceId = getStripePriceId(targetPlanId, currentInterval)
    
    if (!immediatePriceId) {
      throw new Error(`No ${currentInterval}ly price for ${targetPlanId}`)
    }

    const stripeSubscription = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
    const subscriptionItemId = stripeSubscription.items.data[0].id

    // Immediate upgrade with proration
    const upgradedSubscription = await stripe.subscriptions.update(subscription.stripe_subscription_id, {
      items: [{
        id: subscriptionItemId,
        price: immediatePriceId,
      }],
      proration_behavior: 'create_prorations',
    })

    console.log('✅ Step 1: Immediate upgrade completed')

    // Step 2: Create subscription schedule for interval change
    const targetPriceId = getStripePriceId(targetPlanId, targetInterval)
    if (!targetPriceId) {
      throw new Error(`No ${targetInterval}ly price for ${targetPlanId}`)
    }

    const schedule = await stripe.subscriptionSchedules.create({
      from_subscription: subscription.stripe_subscription_id,
    })

    await stripe.subscriptionSchedules.update(schedule.id, {
      phases: [
        // Current phase: upgraded plan at current interval until renewal
        {
          items: [{ price: immediatePriceId, quantity: 1 }],
          start_date: upgradedSubscription.current_period_start,
          end_date: upgradedSubscription.current_period_end,
        },
        // Next phase: target plan at target interval starting at renewal
        {
          items: [{ price: targetPriceId, quantity: 1 }],
          start_date: upgradedSubscription.current_period_end,
        }
      ],
      metadata: {
        ffm_mixed_upgrade: '1',
        ffm_target_plan: targetPlanId,
        ffm_target_interval: targetInterval,
        ffm_original_plan: subscription.plan_id,
        ffm_original_interval: currentInterval
      }
    })

    console.log('✅ Step 2: Interval change scheduled')

    // Step 3: Update database with immediate upgrade + scheduled interval change
    const scheduledChange = {
      planId: targetPlanId,
      interval: targetInterval,
      priceId: targetPriceId,
      effectiveAt: new Date(upgradedSubscription.current_period_end * 1000).toISOString(),
      reason: 'mixed_upgrade_interval_switch'
    }

    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        stripe_price_id: immediatePriceId, // Currently on immediate upgrade price
        plan_id: targetPlanId, // Plan upgraded immediately
        status: upgradedSubscription.status,
        current_period_start: new Date(upgradedSubscription.current_period_start * 1000).toISOString(),
        current_period_end: new Date(upgradedSubscription.current_period_end * 1000).toISOString(),
        cancel_at_period_end: false, // Schedule handles the transition
        metadata: {
          scheduled_change: scheduledChange,
          mixed_upgrade_context: {
            original_plan: subscription.plan_id,
            original_interval: currentInterval,
            immediate_upgrade_price: immediatePriceId,
            target_interval_price: targetPriceId,
            schedule_id: schedule.id,
            upgraded_at: new Date().toISOString()
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

    console.log('✅ Step 3: Database updated with mixed upgrade')

    return {
      success: true,
      type: 'mixed_upgrade',
      subscription: data,
      scheduledChange,
      scheduleId: schedule.id,
      message: `Upgraded to ${targetPlanId} immediately. Billing will switch to ${targetInterval}ly at renewal.`
    }

  } catch (error) {
    console.error('❌ Mixed upgrade failed:', error)
    throw error
  }
}
```

### Alternative Strategy: Schedule Both Changes

```typescript
async function handleScheduleBothChanges(
  stripe: Stripe,
  supabase: any,
  subscription: any,
  targetPlanId: string,
  targetInterval: 'month' | 'year'
) {
  console.log('📅 Strategy: Schedule both plan and interval changes')

  try {
    const targetPriceId = getStripePriceId(targetPlanId, targetInterval)
    if (!targetPriceId) {
      throw new Error(`No price for ${targetPlanId} ${targetInterval}`)
    }

    // Create subscription schedule with delayed changes
    const stripeSubscription = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
    
    const schedule = await stripe.subscriptionSchedules.create({
      from_subscription: subscription.stripe_subscription_id,
    })

    await stripe.subscriptionSchedules.update(schedule.id, {
      phases: [
        // Current phase: keep current plan until renewal
        {
          items: [{ price: subscription.stripe_price_id, quantity: 1 }],
          start_date: stripeSubscription.current_period_start,
          end_date: stripeSubscription.current_period_end,
        },
        // Next phase: target plan and interval starting at renewal
        {
          items: [{ price: targetPriceId, quantity: 1 }],
          start_date: stripeSubscription.current_period_end,
        }
      ],
      metadata: {
        ffm_scheduled_mixed_change: '1',
        ffm_target_plan: targetPlanId,
        ffm_target_interval: targetInterval,
        ffm_change_type: 'scheduled_both'
      }
    })

    // Update database
    const scheduledChange = {
      planId: targetPlanId,
      interval: targetInterval,
      priceId: targetPriceId,
      effectiveAt: new Date(stripeSubscription.current_period_end * 1000).toISOString(),
      reason: 'mixed_upgrade_scheduled'
    }

    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        cancel_at_period_end: false,
        metadata: {
          scheduled_change: scheduledChange,
          scheduled_mixed_change_context: {
            original_plan: subscription.plan_id,
            original_interval: getBillingIntervalFromPrice(subscription.stripe_price_id),
            schedule_id: schedule.id,
            scheduled_at: new Date().toISOString()
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
      type: 'scheduled_mixed_change',
      subscription: data,
      scheduledChange,
      scheduleId: schedule.id,
      message: `Plan and billing changes scheduled for end of current period.`
    }

  } catch (error) {
    console.error('❌ Scheduled mixed change failed:', error)
    throw error
  }
}
```

## Mixed Upgrade UI Components

### Mixed Upgrade Confirmation Modal

```typescript
// components/billing/MixedUpgradeModal.tsx
import { useState, useEffect } from 'react'
import { useProrationPreview } from '@/hooks/useProrationPreview'

interface MixedUpgradeModalProps {
  isOpen: boolean
  onClose: () => void
  currentPlan: string
  currentInterval: 'month' | 'year'
  targetPlan: string
  targetInterval: 'month' | 'year'
  strategy: 'upgrade_now_schedule_interval' | 'schedule_both'
  onConfirm: () => Promise<void>
}

export function MixedUpgradeModal({
  isOpen,
  onClose,
  currentPlan,
  currentInterval,
  targetPlan,
  targetInterval,
  strategy,
  onConfirm
}: MixedUpgradeModalProps) {
  const [confirming, setConfirming] = useState(false)
  const { preview, loading, calculatePreview } = useProrationPreview()

  useEffect(() => {
    if (isOpen && strategy === 'upgrade_now_schedule_interval') {
      // Preview the immediate upgrade portion
      const immediatePriceId = getStripePriceId(targetPlan, currentInterval)
      if (immediatePriceId) {
        calculatePreview({
          newPriceId: immediatePriceId,
          billingInterval: currentInterval
        })
      }
    }
  }, [isOpen, targetPlan, currentInterval, strategy])

  const handleConfirm = async () => {
    setConfirming(true)
    try {
      await onConfirm()
      onClose()
    } catch (error) {
      console.error('Mixed upgrade failed:', error)
    } finally {
      setConfirming(false)
    }
  }

  if (!isOpen) return null

  const isUpgradeNowStrategy = strategy === 'upgrade_now_schedule_interval'

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg p-6 max-w-2xl w-full mx-4 max-h-[90vh] overflow-y-auto">
        <h3 className="text-lg font-semibold mb-4">
          Upgrade to {targetPlan} ({targetInterval === 'year' ? 'Annual' : 'Monthly'})
        </h3>

        {/* Scenario Explanation */}
        <div className="mb-6">
          <p className="text-gray-600 mb-4">
            You're upgrading from <strong>{currentPlan} ({currentInterval}ly)</strong> to{' '}
            <strong>{targetPlan} ({targetInterval}ly)</strong>.
          </p>

          {isUpgradeNowStrategy ? (
            <div className="bg-blue-50 border border-blue-200 rounded-lg p-4">
              <h4 className="font-medium text-blue-800 mb-2">
                Upgrade Strategy: Immediate Benefits + Scheduled Billing Change
              </h4>
              <div className="text-sm text-blue-700 space-y-2">
                <div className="flex items-start">
                  <span className="font-medium mr-2">1.</span>
                  <span>
                    <strong>Immediate upgrade</strong> to {targetPlan} features 
                    (you'll get all the benefits right away)
                  </span>
                </div>
                <div className="flex items-start">
                  <span className="font-medium mr-2">2.</span>
                  <span>
                    <strong>Proration applies</strong> for the upgrade to higher plan tier
                  </span>
                </div>
                <div className="flex items-start">
                  <span className="font-medium mr-2">3.</span>
                  <span>
                    <strong>Billing switches to {targetInterval}ly</strong> at your next renewal
                  </span>
                </div>
              </div>
            </div>
          ) : (
            <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4">
              <h4 className="font-medium text-yellow-800 mb-2">
                Upgrade Strategy: Scheduled Changes
              </h4>
              <div className="text-sm text-yellow-700 space-y-2">
                <div className="flex items-start">
                  <span className="font-medium mr-2">1.</span>
                  <span>
                    Changes take effect at the end of your current billing period
                  </span>
                </div>
                <div className="flex items-start">
                  <span className="font-medium mr-2">2.</span>
                  <span>
                    You'll keep current plan benefits until then
                  </span>
                </div>
                <div className="flex items-start">
                  <span className="font-medium mr-2">3.</span>
                  <span>
                    No immediate charges - changes at renewal
                  </span>
                </div>
              </div>
            </div>
          )}
        </div>

        {/* Proration Preview for Immediate Strategy */}
        {isUpgradeNowStrategy && (
          <div className="mb-6">
            {loading ? (
              <div className="p-4 bg-gray-50 rounded">
                <p className="text-sm text-gray-600">Calculating upgrade costs...</p>
              </div>
            ) : preview ? (
              <div className="p-4 bg-gray-50 rounded">
                <h4 className="font-medium mb-2">Immediate Upgrade Cost</h4>
                <div className="space-y-2 text-sm">
                  <div className="flex justify-between">
                    <span>Due today (prorated):</span>
                    <span className="font-medium">${preview.amountDue.toFixed(2)}</span>
                  </div>
                  <div className="text-xs text-gray-600">
                    This covers the plan upgrade for the remainder of your current billing period.
                  </div>
                </div>
              </div>
            ) : null}
          </div>
        )}

        {/* Timeline Display */}
        <div className="mb-6">
          <h4 className="font-medium mb-3">Change Timeline</h4>
          <div className="space-y-3">
            <div className="flex items-center">
              <div className="w-3 h-3 bg-green-500 rounded-full mr-3"></div>
              <div className="text-sm">
                <span className="font-medium">Now:</span>{' '}
                {isUpgradeNowStrategy 
                  ? `Upgrade to ${targetPlan} features immediately`
                  : 'No changes - keep current plan'
                }
              </div>
            </div>
            
            <div className="flex items-center">
              <div className="w-3 h-3 bg-blue-500 rounded-full mr-3"></div>
              <div className="text-sm">
                <span className="font-medium">At renewal:</span>{' '}
                {isUpgradeNowStrategy
                  ? `Switch to ${targetInterval}ly billing`
                  : `Upgrade to ${targetPlan} and switch to ${targetInterval}ly billing`
                }
              </div>
            </div>
          </div>
        </div>

        {/* Action Buttons */}
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
            {confirming ? 'Processing...' : 'Confirm Changes'}
          </button>
        </div>
      </div>
    </div>
  )
}
```

### Mixed Upgrade Hook

```typescript
// hooks/useMixedUpgrade.ts
import { useState } from 'react'

export function useMixedUpgrade() {
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const executeMixedUpgrade = async (
    targetPlanId: string,
    targetInterval: 'month' | 'year'
  ) => {
    setLoading(true)
    setError(null)

    try {
      const response = await fetch('/api/billing/mixed-upgrade', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          targetPlanId,
          targetInterval
        }),
      })

      const data = await response.json()

      if (!response.ok) {
        throw new Error(data.error || 'Mixed upgrade failed')
      }

      return data
    } catch (err) {
      const message = err instanceof Error ? err.message : 'An error occurred'
      setError(message)
      throw err
    } finally {
      setLoading(false)
    }
  }

  return {
    executeMixedUpgrade,
    loading,
    error
  }
}
```

## Mixed Upgrade API Endpoint

```typescript
// billing/mixed-upgrade.ts - Framework-agnostic mixed upgrade handler
export async function handleMixedUpgrade(request: Request): Promise<Response> {
  try {
    // Extract user context (implementation varies by framework)
    const user = await getUserFromRequest(request)
    if (!user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const { targetPlanId, targetInterval } = await request.json()
    
    if (!targetPlanId || !targetInterval) {
      return new Response(
        JSON.stringify({ 
          error: 'Missing targetPlanId or targetInterval' 
        }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Get current subscription
    const { data: subscription, error: subError } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('user_id', user.id)
      .order('updated_at', { ascending: false })
      .limit(1)
      .single()

    if (subError || !subscription?.stripe_subscription_id) {
      return new Response(
        JSON.stringify({ error: 'No active subscription found' }),
        { status: 404, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Validate this is a mixed upgrade scenario
    if (!isMixedUpgradeScenario(subscription, targetPlanId, targetInterval)) {
      return new Response(
        JSON.stringify({ 
          error: 'Not a valid mixed upgrade scenario. Use regular upgrade/downgrade endpoints.' 
        }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Validate the plan transition is allowed
    if (!canUpgradeTo(subscription.plan_id, targetPlanId)) {
      return new Response(
        JSON.stringify({ 
          error: 'Plan upgrade not allowed',
          allowedUpgrades: getPlanConfig(subscription.plan_id)?.upgradePlans || []
        }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil',
    })

    // Execute mixed upgrade
    const result = await handleMixedUpgrade(
      stripe,
      supabase,
      subscription,
      targetPlanId,
      targetInterval
    )

    return new Response(
      JSON.stringify(result),
      { headers: { 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Mixed upgrade failed:', error)
    return new Response(
      JSON.stringify({ error: 'Mixed upgrade failed' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

## Testing Mixed Upgrades

### E2E Tests

```typescript
// cypress/e2e/billing/mixed-upgrades.cy.ts
describe('Mixed Upgrade Scenarios', () => {
  describe('Pro Annual → Scale Monthly', () => {
    const email = `pro-annual-to-scale-monthly-${Date.now()}@example.com`

    beforeEach(() => {
      cy.seedProAnnualUser({ email })
      cy.login(email)
    })

    it('should upgrade immediately and schedule interval switch', () => {
      cy.visit('/billing')

      // Verify starting state
      cy.get('[data-testid="current-plan-name"]').should('contain', 'Pro')
      cy.get('[data-testid="current-plan-interval"]').should('contain', 'Annual')

      // Switch to monthly view and select Scale
      cy.get('[data-testid="billing-toggle-monthly"]').click()
      cy.get('[data-testid="scale-action-button"]').click()

      // Should show mixed upgrade modal
      cy.get('[data-testid="mixed-upgrade-modal"]').should('be.visible')
      cy.get('[data-testid="upgrade-strategy"]').should('contain', 'Immediate Benefits')
      cy.get('[data-testid="proration-preview"]').should('be.visible')

      // Should show timeline
      cy.get('[data-testid="change-timeline"]').should('be.visible')
      cy.get('[data-testid="immediate-change"]').should('contain', 'Scale features immediately')
      cy.get('[data-testid="scheduled-change"]').should('contain', 'monthly billing')

      // Confirm mixed upgrade
      cy.intercept('POST', '/api/billing/mixed-upgrade').as('mixedUpgrade')
      cy.get('[data-testid="confirm-mixed-upgrade"]').click()

      cy.wait('@mixedUpgrade').then((interception) => {
        expect(interception.response?.statusCode).to.eq(200)
        expect(interception.response?.body.type).to.eq('mixed_upgrade')
      })

      // Should show success message
      cy.get('[data-testid="mixed-upgrade-success"]').should('be.visible')

      // Should show scheduled change banner
      cy.get('[data-testid="scheduled-change-banner"]').should('be.visible')
      cy.get('[data-testid="scheduled-change-banner"]').should('contain', 'monthly')

      // Verify immediate plan change
      cy.reload()
      cy.get('[data-testid="current-plan-name"]').should('contain', 'Scale')
    })
  })

  describe('Starter Monthly → Pro Annual', () => {
    const email = `starter-monthly-to-pro-annual-${Date.now()}@example.com`

    beforeEach(() => {
      cy.seedStarterUser({ email })
      cy.login(email)
    })

    it('should handle upgrade with interval change to annual', () => {
      cy.visit('/billing')

      // Switch to annual view and select Pro
      cy.get('[data-testid="billing-toggle-annual"]').click()
      cy.get('[data-testid="pro-action-button"]').click()

      // Should show upgrade modal (not mixed upgrade - this is simple)
      cy.get('[data-testid="upgrade-confirmation-modal"]').should('be.visible')
      cy.get('[data-testid="upgrade-modal-body"]').should('contain', 'immediate')

      // Should show annual savings
      cy.get('[data-testid="annual-savings"]').should('be.visible')

      cy.intercept('POST', '/api/billing/upgrade').as('upgrade')
      cy.get('[data-testid="confirm-upgrade"]').click()

      cy.wait('@upgrade').then((interception) => {
        expect(interception.response?.statusCode).to.eq(200)
      })

      // Should immediately switch to Pro Annual
      cy.reload()
      cy.get('[data-testid="current-plan-name"]').should('contain', 'Pro')
      cy.get('[data-testid="current-plan-interval"]').should('contain', 'Annual')
    })
  })
})
```

## Mixed Upgrade Analytics

### Tracking Mixed Upgrade Patterns

```typescript
// lib/mixed-upgrade-analytics.ts
export async function trackMixedUpgradeEvent(
  userId: string,
  upgrade: {
    fromPlan: string
    fromInterval: string
    toPlan: string
    toInterval: string
    strategy: string
    prorationAmount?: number
  }
) {
  try {
    const analytics = {
      event: 'mixed_upgrade_completed',
      userId,
      timestamp: new Date().toISOString(),
      properties: {
        from_plan: upgrade.fromPlan,
        from_interval: upgrade.fromInterval,
        to_plan: upgrade.toPlan,
        to_interval: upgrade.toInterval,
        upgrade_strategy: upgrade.strategy,
        proration_amount: upgrade.prorationAmount,
        plan_tier_change: calculatePlanTierChange(upgrade.fromPlan, upgrade.toPlan),
        interval_direction: upgrade.fromInterval === 'year' && upgrade.toInterval === 'month' 
          ? 'annual_to_monthly' 
          : 'monthly_to_annual'
      }
    }

    // Send to analytics service
    await analyticsService.track(analytics)

    // Store in database for internal reporting
    const supabase = createServerServiceRoleClient()
    await supabase
      .from('upgrade_events')
      .insert({
        user_id: userId,
        event_type: 'mixed_upgrade',
        event_data: analytics.properties,
        created_at: new Date().toISOString()
      })

    console.log('✅ Mixed upgrade event tracked')
  } catch (error) {
    console.error('❌ Error tracking mixed upgrade event:', error)
  }
}

function calculatePlanTierChange(fromPlan: string, toPlan: string): number {
  const planTiers = { free: 0, starter: 1, pro: 2, scale: 3 }
  return (planTiers[toPlan as keyof typeof planTiers] || 0) - 
         (planTiers[fromPlan as keyof typeof planTiers] || 0)
}
```

## Next Steps

In the next module, we'll cover cancellation flows, reactivation scenarios, and grace period management.

## Key Takeaways

- Mixed upgrades require combining immediate upgrades with scheduled interval changes
- Use subscription schedules to coordinate complex timing requirements
- Provide clear explanation of the upgrade strategy to users
- Show proration previews for immediate upgrade portions
- Track mixed upgrade analytics for business insights
- Test complex scenarios thoroughly with realistic user flows
- Handle edge cases where mixed upgrades aren't supported
- Use appropriate UI components to explain complex changes
- Store upgrade context in metadata for troubleshooting
- Coordinate between immediate changes and scheduled changes seamlessly
