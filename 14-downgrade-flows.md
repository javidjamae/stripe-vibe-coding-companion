# Downgrade Flows and Scheduled Changes

## Overview

This module covers implementing plan downgrade flows, including scheduled downgrades at period end, immediate downgrades to free plans, and the complex downgrade logic patterns found in your codebase.

## Downgrade Strategy

Your codebase implements a sophisticated downgrade strategy:

1. **Immediate Downgrades**: Only for free plan (no billing impact)
2. **Scheduled Downgrades**: For paid-to-paid plan changes (preserve billing value)
3. **Cancel-First Flow**: Handle existing scheduled changes before new ones

## Downgrade to Free Implementation

### Free Plan Downgrade Logic

```typescript
// app/api/billing/downgrade-to-free/logic.ts
export async function downgradeToFree(
  supabase: SupabaseClient,
  stripe: StripeClient,
  userId: string,
  isTestMode: boolean = false
): Promise<DowngradeResult | DowngradeError> {
  try {
    // Get user's active subscription using RPC function
    const { data: subscriptionData, error: subError } = await supabase
      .rpc('get_user_active_subscription', { user_uuid: userId })

    if (subError || !subscriptionData || subscriptionData.length === 0) {
      return {
        error: 'No active subscription found',
        status: 404
      }
    }

    const subscription = subscriptionData[0]

    if (!subscription.stripe_subscription_id && !isTestMode) {
      return {
        error: 'Subscription not linked to Stripe',
        status: 400
      }
    }

    if (subscription.plan_type === 'free') {
      return {
        error: 'User is already on free plan',
        status: 400
      }
    }

    let stripeSubscription: any = null

    if (isTestMode) {
      // Mock Stripe call for tests
      const testEndDate = new Date()
      testEndDate.setDate(testEndDate.getDate() + 20) // 20 days for testing
      
      stripeSubscription = {
        current_period_end: Math.floor(testEndDate.getTime() / 1000)
      }
    } else {
      // Real Stripe call - schedule cancellation at period end
      stripeSubscription = await stripe.subscriptions.update(
        subscription.stripe_subscription_id!,
        {
          cancel_at_period_end: true,
        }
      )
    }

    // Compute scheduled_change metadata for UI display
    const epoch = stripeSubscription?.current_period_end as number | undefined
    const effectiveAt = epoch ? new Date(epoch * 1000).toISOString() : subscription.current_period_end
    
    const scheduledChange = {
      planId: 'free',
      interval: 'month' as const,
      priceId: getStripePriceId('free', 'month'),
      effectiveAt,
    }

    // Update database to reflect scheduled downgrade
    const { error: updateError } = await supabase
      .from('subscriptions')
      .update({
        cancel_at_period_end: true,
        updated_at: new Date().toISOString(),
        metadata: {
          scheduled_change: scheduledChange,
        } as any,
      })
      .eq('id', subscription.id)

    if (updateError) {
      console.error('Failed to update subscription in database:', updateError)
      return {
        error: 'Failed to update subscription',
        status: 500
      }
    }

    return {
      success: true,
      subscription: {
        id: subscription.id,
        cancelAtPeriodEnd: true,
        currentPeriodEnd: stripeSubscription.current_period_end 
          ? new Date(stripeSubscription.current_period_end * 1000).toISOString()
          : subscription.current_period_end,
        status: subscription.status,
        planType: subscription.plan_type,
      }
    }

  } catch (error) {
    console.error('Error in downgrade-to-free:', error)
    return {
      error: 'Internal server error',
      status: 500
    }
  }
}
```

### Free Downgrade API Endpoint

```typescript
// app/api/billing/downgrade-to-free/route.ts
export async function POST(req: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    // Check for test mode (used in Cypress tests)
    const isTestMode = req.headers.get('x-test-mode') === 'cypress'
    
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil',
    })
    
    // Use business logic function
    const result = await downgradeToFree(supabase, stripe, user.id, isTestMode)
    
    if ('error' in result) {
      return new Response(
      JSON.stringify({ error: result.error ),
      { status: result.status })
    }

    return new Response(
      JSON.stringify({
      success: true,
      message: 'Downgrade to Free scheduled successfully',
      subscription: result.subscription
    })

  } catch (error) {
    console.error('Downgrade to free failed:', error)
    return new Response(
      JSON.stringify({ error: 'Internal server error' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Paid Plan Downgrades

### Paid Downgrade Logic

```typescript
// app/api/billing/downgrade/route.ts
export async function POST(req: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    const { newPlanId, newPriceId, billingInterval } = await req.json()
    
    if (!newPlanId) {
      return new Response(
      JSON.stringify({ error: 'Missing newPlanId' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
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
      JSON.stringify({ error: 'No active subscription found' ),
      { status: 404 })
    }

    // Validate downgrade is allowed
    if (!canDowngradeTo(subscription.plan_id, newPlanId)) {
      return new Response(
      JSON.stringify({ 
        error: 'Downgrade not allowed',
        allowedDowngrades: getPlanConfig(subscription.plan_id)?.downgradePlans || []
      ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil',
    })

    // Determine if interval is changing
    const currentInterval = getBillingIntervalFromPrice(subscription.stripe_price_id)
    const targetInterval = billingInterval || 'month'
    const intervalChanging = currentInterval !== targetInterval

    if (intervalChanging) {
      // Use subscription schedule for interval changes
      return await handleDowngradeWithSchedule(
        stripe, 
        supabase, 
        subscription, 
        newPlanId, 
        targetInterval
      )
    } else {
      // Simple downgrade - same interval
      return await handleSimpleDowngrade(
        stripe, 
        supabase, 
        subscription, 
        newPlanId, 
        targetInterval
      )
    }

  } catch (error) {
    console.error('Downgrade failed:', error)
    return new Response(
      JSON.stringify({ error: 'Downgrade failed' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

### Simple Downgrade Handler

```typescript
// lib/downgrade-handlers.ts
export async function handleSimpleDowngrade(
  stripe: Stripe,
  supabase: any,
  subscription: any,
  newPlanId: string,
  billingInterval: 'month' | 'year'
) {
  console.log('⬇️ Processing simple downgrade (same interval)')
  
  try {
    const newPriceId = getStripePriceId(newPlanId, billingInterval)
    if (!newPriceId) {
      throw new Error(`No price found for ${newPlanId} ${billingInterval}`)
    }

    // Get current subscription from Stripe
    const stripeSubscription = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
    
    // Schedule downgrade at period end by setting cancel_at_period_end
    // The webhook will handle creating the new subscription
    const updatedSubscription = await stripe.subscriptions.update(subscription.stripe_subscription_id, {
      cancel_at_period_end: true,
      metadata: {
        scheduled_downgrade_plan: newPlanId,
        scheduled_downgrade_price: newPriceId,
        scheduled_downgrade_interval: billingInterval
      }
    })

    // Create scheduled change metadata for UI
    const scheduledChange = {
      planId: newPlanId,
      interval: billingInterval,
      priceId: newPriceId,
      effectiveAt: new Date(updatedSubscription.current_period_end * 1000).toISOString(),
    }

    // Update database
    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        cancel_at_period_end: true,
        metadata: {
          scheduled_change: scheduledChange,
          downgrade_context: {
            original_plan: subscription.plan_id,
            original_interval: getBillingIntervalFromPrice(subscription.stripe_price_id),
            downgrade_type: 'simple'
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

    console.log('✅ Simple downgrade scheduled')
    return new Response(
      JSON.stringify({
      success: true,
      message: `Downgrade to ${newPlanId} scheduled for end of billing period`,
      subscription: data,
      scheduledChange
    })

  } catch (error) {
    console.error('❌ Simple downgrade failed:', error)
    throw error
  }
}
```

### Schedule-Based Downgrade Handler

```typescript
export async function handleDowngradeWithSchedule(
  stripe: Stripe,
  supabase: any,
  subscription: any,
  newPlanId: string,
  targetInterval: 'month' | 'year'
) {
  console.log('📅 Processing downgrade with subscription schedule (interval change)')
  
  try {
    const newPriceId = getStripePriceId(newPlanId, targetInterval)
    if (!newPriceId) {
      throw new Error(`No price found for ${newPlanId} ${targetInterval}`)
    }

    // Get current subscription from Stripe
    const stripeSubscription = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
    
    // Create subscription schedule from current subscription
    const schedule = await stripe.subscriptionSchedules.create({
      from_subscription: subscription.stripe_subscription_id,
    })

    // Update schedule with two phases:
    // Phase 1: Current plan until period end
    // Phase 2: New plan starting at period end
    await stripe.subscriptionSchedules.update(schedule.id, {
      phases: [
        {
          items: [{ 
            price: subscription.stripe_price_id, 
            quantity: 1 
          }],
          start_date: stripeSubscription.current_period_start,
          end_date: stripeSubscription.current_period_end,
        },
        {
          items: [{ 
            price: newPriceId, 
            quantity: 1 
          }],
          start_date: stripeSubscription.current_period_end,
        }
      ],
      metadata: {
        ffm_downgrade: '1',
        ffm_target_plan: newPlanId,
        ffm_target_interval: targetInterval
      }
    })

    // Create scheduled change metadata for UI
    const scheduledChange = {
      planId: newPlanId,
      interval: targetInterval,
      priceId: newPriceId,
      effectiveAt: new Date(stripeSubscription.current_period_end * 1000).toISOString(),
    }

    // Update database - don't set cancel_at_period_end for schedules
    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        cancel_at_period_end: false, // Important: schedules handle the transition
        metadata: {
          scheduled_change: scheduledChange,
          downgrade_context: {
            original_plan: subscription.plan_id,
            original_interval: getBillingIntervalFromPrice(subscription.stripe_price_id),
            downgrade_type: 'schedule_with_interval_change',
            schedule_id: schedule.id
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

    console.log('✅ Downgrade with schedule created')
    return new Response(
      JSON.stringify({
      success: true,
      message: `Downgrade to ${newPlanId} (${targetInterval}ly) scheduled for end of billing period`,
      subscription: data,
      scheduledChange,
      scheduleId: schedule.id
    })

  } catch (error) {
    console.error('❌ Schedule-based downgrade failed:', error)
    throw error
  }
}
```

## Cancel Plan Change Flow

Your codebase implements a "cancel-first" flow for handling existing scheduled changes:

### Cancel Plan Change API

```typescript
// app/api/billing/cancel-plan-change/route.ts
export async function POST(req: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    // Get current subscription
    const { data: subscription, error: subError } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('user_id', user.id)
      .order('updated_at', { ascending: false })
      .limit(1)
      .single()

    if (subError || !subscription) {
      return new Response(
      JSON.stringify({ error: 'No subscription found' ),
      { status: 404 })
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil',
    })

    let cancelledSchedule = false
    let cancelledFlag = false

    // Step 1: Try to cancel any active subscription schedules
    try {
      const schedules = await stripe.subscriptionSchedules.list({
        subscription: subscription.stripe_subscription_id,
        limit: 1
      })

      if (schedules.data.length > 0) {
        const schedule = schedules.data[0]
        if (schedule.status === 'active') {
          await stripe.subscriptionSchedules.cancel(schedule.id)
          cancelledSchedule = true
          console.log(`✅ Cancelled subscription schedule: ${schedule.id}`)
        }
      }
    } catch (error) {
      console.log('No active schedules found or schedule cancellation failed:', error)
    }

    // Step 2: Clear cancel_at_period_end flag if no schedule was cancelled
    if (!cancelledSchedule && subscription.cancel_at_period_end) {
      await stripe.subscriptions.update(subscription.stripe_subscription_id, {
        cancel_at_period_end: false
      })
      cancelledFlag = true
      console.log('✅ Cleared cancel_at_period_end flag')
    }

    // Step 3: Clear scheduled_change metadata in database
    const currentMetadata = (subscription.metadata || {}) as any
    if (currentMetadata.scheduled_change) {
      const { scheduled_change, downgrade_context, upgrade_context, ...remainingMetadata } = currentMetadata

      const { data, error } = await supabase
        .from('subscriptions')
        .update({
          cancel_at_period_end: false,
          metadata: remainingMetadata,
          updated_at: new Date().toISOString()
        })
        .eq('id', subscription.id)
        .select()
        .single()

      if (error) {
        console.error('❌ Error clearing scheduled change metadata:', error)
        throw error
      }

      console.log('✅ Cleared scheduled_change metadata')
    }

    return new Response(
      JSON.stringify({
      success: true,
      message: 'Scheduled plan change cancelled',
      actions: {
        cancelledSchedule,
        cancelledFlag,
        clearedMetadata: !!currentMetadata.scheduled_change
      }
    })

  } catch (error) {
    console.error('Cancel plan change failed:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to cancel plan change' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Downgrade UI Components

### Downgrade Confirmation Modal

```typescript
// components/billing/DowngradeModal.tsx
interface DowngradeModalProps {
  isOpen: boolean
  onClose: () => void
  currentPlan: string
  targetPlan: string
  currentPeriodEnd: string
  onConfirm: () => Promise<void>
}

export function DowngradeModal({
  isOpen,
  onClose,
  currentPlan,
  targetPlan,
  currentPeriodEnd,
  onConfirm
}: DowngradeModalProps) {
  const [loading, setLoading] = useState(false)
  
  const handleConfirm = async () => {
    setLoading(true)
    try {
      await onConfirm()
      onClose()
    } catch (error) {
      console.error('Downgrade failed:', error)
    } finally {
      setLoading(false)
    }
  }

  if (!isOpen) return null

  const endDate = new Date(currentPeriodEnd).toLocaleDateString()

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg p-6 max-w-md w-full mx-4">
        <h3 className="text-lg font-semibold mb-4">
          Downgrade to {targetPlan}
        </h3>

        <div className="mb-4">
          <p className="text-gray-600 mb-2">
            Are you sure you want to downgrade from <strong>{currentPlan}</strong> to <strong>{targetPlan}</strong>?
          </p>
          
          <div className="bg-blue-50 p-3 rounded-md">
            <p className="text-sm text-blue-800">
              <strong>Your {currentPlan} plan will remain active until {endDate}</strong>
            </p>
            <p className="text-sm text-blue-600 mt-1">
              After that date, you'll be switched to {targetPlan} for your next billing cycle.
            </p>
          </div>

          {targetPlan === 'Free' && (
            <div className="bg-yellow-50 p-3 rounded-md mt-3">
              <p className="text-sm text-yellow-800">
                <strong>Note:</strong> Downgrading to Free will cancel your subscription. 
                You can resubscribe at any time.
              </p>
            </div>
          )}
        </div>

        <div className="flex space-x-3">
          <button
            onClick={onClose}
            disabled={loading}
            className="flex-1 px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 disabled:opacity-50"
          >
            Keep {currentPlan}
          </button>
          <button
            onClick={handleConfirm}
            disabled={loading}
            className="flex-1 px-4 py-2 bg-gray-600 text-white rounded-md hover:bg-gray-700 disabled:opacity-50"
          >
            {loading ? 'Processing...' : `Switch to ${targetPlan}`}
          </button>
        </div>
      </div>
    </div>
  )
}
```

### Cancel Downgrade Modal

```typescript
// components/billing/CancelDowngradeModal.tsx
export function CancelDowngradeModal({
  isOpen,
  onClose,
  scheduledChange,
  onConfirm
}: {
  isOpen: boolean
  onClose: () => void
  scheduledChange: any
  onConfirm: () => Promise<void>
}) {
  const [loading, setLoading] = useState(false)

  const handleCancel = async () => {
    setLoading(true)
    try {
      await onConfirm()
      onClose()
    } catch (error) {
      console.error('Cancel failed:', error)
    } finally {
      setLoading(false)
    }
  }

  if (!isOpen) return null

  const effectiveDate = new Date(scheduledChange.effectiveAt).toLocaleDateString()

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg p-6 max-w-md w-full mx-4">
        <h3 className="text-lg font-semibold mb-4">
          Cancel Scheduled Plan Change
        </h3>

        <div className="mb-4">
          <p className="text-gray-600 mb-2">
            You have a scheduled change to <strong>{scheduledChange.planId}</strong> 
            that will take effect on <strong>{effectiveDate}</strong>.
          </p>
          
          <p className="text-gray-600">
            Would you like to cancel this scheduled change?
          </p>
        </div>

        <div className="flex space-x-3">
          <button
            onClick={onClose}
            disabled={loading}
            className="flex-1 px-4 py-2 border border-gray-300 rounded-md text-gray-700 hover:bg-gray-50 disabled:opacity-50"
          >
            Keep Scheduled Change
          </button>
          <button
            onClick={handleCancel}
            disabled={loading}
            className="flex-1 px-4 py-2 bg-red-600 text-white rounded-md hover:bg-red-700 disabled:opacity-50"
          >
            {loading ? 'Cancelling...' : 'Cancel Scheduled Change'}
          </button>
        </div>
      </div>
    </div>
  )
}
```

## Testing Downgrade Flows

### Cypress E2E Tests

```typescript
// cypress/e2e/billing/downgrade-flow.cy.ts
describe('Downgrade Flow', () => {
  beforeEach(() => {
    cy.seedStarterUser({ email: 'starter-user@example.com' })
    cy.login('starter-user@example.com')
  })

  it('should schedule downgrade to free plan', () => {
    cy.visit('/billing')
    
    // Click on Free plan
    cy.get('[data-testid="free-action-button"]').click()
    
    // Downgrade modal should appear
    cy.get('[data-testid="downgrade-modal"]').should('be.visible')
    cy.get('[data-testid="downgrade-modal-title"]').should('contain', 'Downgrade to Free Plan')
    
    // Should show scheduling information
    cy.get('[data-testid="downgrade-modal-body"]').should('contain', 'remain active until')
    
    // Intercept downgrade API
    cy.intercept('POST', '/api/billing/downgrade-to-free').as('downgradeApi')
    
    // Confirm downgrade
    cy.get('[data-testid="confirm-downgrade-button"]').click()
    
    // Wait for API call
    cy.wait('@downgradeApi').then((interception) => {
      expect(interception.response?.statusCode).to.eq(200)
    })
    
    // Should show success message
    cy.get('[data-testid="downgrade-success-toast"]').should('be.visible')
    
    // Reload and verify scheduled change is shown
    cy.reload()
    cy.get('[data-testid="current-plan-price"]').should('contain', 'until')
    cy.get('[data-testid="current-plan-price"]').should('contain', 'then $0/month')
  })

  it('should handle cancel-first flow for existing scheduled changes', () => {
    // Seed user with existing scheduled downgrade
    cy.seedStarterUserWithScheduledDowngrade('starter-scheduled@example.com')
    cy.login('starter-scheduled@example.com')
    
    cy.visit('/billing')
    
    // Try to select a different plan
    cy.get('[data-testid="pro-action-button"]').click()
    
    // Should show cancel-first modal
    cy.get('[data-testid="cancel-downgrade-modal"]').should('be.visible')
    cy.get('[data-testid="cancel-downgrade-modal"]').should('contain', 'scheduled change')
    
    // Cancel the scheduled change
    cy.intercept('POST', '/api/billing/cancel-plan-change').as('cancelApi')
    cy.get('[data-testid="cancel-scheduled-change-button"]').click()
    
    cy.wait('@cancelApi').then((interception) => {
      expect(interception.response?.statusCode).to.eq(200)
    })
    
    // Should proceed to upgrade flow
    cy.get('[data-testid="upgrade-confirmation-modal"]').should('be.visible')
  })
})
```

## Next Steps

In the next module, we'll cover interval changes and the complex scenarios around switching between monthly and annual billing.

## Key Takeaways

- Implement scheduled downgrades to preserve billing value
- Use `cancel_at_period_end` for simple downgrades to free
- Use subscription schedules for downgrades with interval changes
- Implement cancel-first flow for existing scheduled changes
- Store scheduled change metadata for UI display
- Handle both immediate and scheduled downgrades appropriately
- Provide clear messaging about when changes take effect
- Test downgrade flows with realistic user scenarios
- Validate downgrade permissions before processing
- Handle edge cases like existing scheduled changes gracefully
