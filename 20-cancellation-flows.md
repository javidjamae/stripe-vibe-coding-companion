# Cancellation Flows and Reactivation

## Overview

This module covers implementing subscription cancellation flows, handling reactivation scenarios, and managing grace periods. We'll explore patterns for retaining customers while providing flexible cancellation options.

## Cancellation Strategy

Your codebase implements a customer-friendly cancellation approach:

### Cancellation Types

1. **Immediate Cancellation**: Rare, typically for policy violations
2. **End-of-Period Cancellation**: Most common, preserves paid value
3. **Downgrade to Free**: Maintains account, removes paid features
4. **Account Deletion**: Complete removal (GDPR compliance)

### Grace Period Philosophy

- Users keep access until period end
- No immediate feature restriction
- Opportunity for reactivation
- Clear communication about when access ends

## Cancellation Implementation

### Cancel at Period End

```typescript
// lib/cancellation-flows.ts
export async function cancelSubscriptionAtPeriodEnd(
  userId: string,
  reason?: string,
  feedback?: string
): Promise<{
  success: boolean
  subscription?: any
  effectiveDate?: string
  error?: string
}> {
  
  console.log(`🚫 Cancelling subscription for user ${userId}`)

  try {
    const supabase = createServerUserClient()
    
    // Get current subscription
    const { data: subscription, error: subError } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('user_id', userId)
      .order('updated_at', { ascending: false })
      .limit(1)
      .single()

    if (subError || !subscription) {
      return { success: false, error: 'No active subscription found' }
    }

    if (subscription.cancel_at_period_end) {
      return { success: false, error: 'Subscription already scheduled for cancellation' }
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    // Cancel at period end in Stripe
    const stripeSubscription = await stripe.subscriptions.update(subscription.stripe_subscription_id, {
      cancel_at_period_end: true,
      metadata: {
        cancellation_reason: reason || 'user_requested',
        cancelled_at: new Date().toISOString(),
        user_feedback: feedback || ''
      }
    })

    // Update database
    const scheduledChange = {
      planId: 'free',
      interval: 'month' as const,
      priceId: getStripePriceId('free', 'month'),
      effectiveAt: new Date(stripeSubscription.current_period_end * 1000).toISOString(),
      reason: 'cancellation'
    }

    const { data: updatedSub, error: updateError } = await supabase
      .from('subscriptions')
      .update({
        cancel_at_period_end: true,
        metadata: {
          scheduled_change: scheduledChange,
          cancellation_context: {
            reason: reason || 'user_requested',
            feedback: feedback || '',
            cancelled_at: new Date().toISOString(),
            effective_at: scheduledChange.effectiveAt
          }
        },
        updated_at: new Date().toISOString()
      })
      .eq('id', subscription.id)
      .select()
      .single()

    if (updateError) {
      console.error('❌ Database update failed:', updateError)
      throw updateError
    }

    // Track cancellation event
    await trackCancellationEvent(userId, {
      plan: subscription.plan_id,
      reason: reason || 'user_requested',
      feedback,
      effectiveDate: scheduledChange.effectiveAt
    })

    // Send cancellation confirmation email
    await sendCancellationConfirmationEmail(userId, {
      effectiveDate: scheduledChange.effectiveAt,
      plan: subscription.plan_id
    })

    console.log('✅ Subscription cancelled at period end')
    return {
      success: true,
      subscription: updatedSub,
      effectiveDate: scheduledChange.effectiveAt
    }

  } catch (error) {
    console.error('❌ Cancellation failed:', error)
    return { 
      success: false, 
      error: error instanceof Error ? error.message : 'Cancellation failed' 
    }
  }
}
```

### Immediate Cancellation (Admin Only)

```typescript
export async function cancelSubscriptionImmediately(
  userId: string,
  adminReason: string,
  adminUserId: string
): Promise<{ success: boolean; error?: string }> {
  
  console.log(`⚠️ Immediate cancellation for user ${userId} by admin ${adminUserId}`)

  try {
    const supabase = createServerServiceRoleClient()
    
    const { data: subscription, error } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('user_id', userId)
      .single()

    if (error || !subscription) {
      return { success: false, error: 'Subscription not found' }
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    // Cancel immediately in Stripe
    await stripe.subscriptions.cancel(subscription.stripe_subscription_id, {
      prorate: true, // Prorate any unused time
      invoice_now: true // Create final invoice
    })

    // Update database
    const { error: updateError } = await supabase
      .from('subscriptions')
      .update({
        status: 'canceled',
        cancel_at_period_end: false,
        metadata: {
          immediate_cancellation: {
            reason: adminReason,
            cancelled_by: adminUserId,
            cancelled_at: new Date().toISOString()
          }
        },
        updated_at: new Date().toISOString()
      })
      .eq('id', subscription.id)

    if (updateError) {
      throw updateError
    }

    // Log admin action
    await logAdminAction({
      adminUserId,
      action: 'immediate_cancellation',
      targetUserId: userId,
      reason: adminReason
    })

    console.log('✅ Immediate cancellation completed')
    return { success: true }

  } catch (error) {
    console.error('❌ Immediate cancellation failed:', error)
    return { 
      success: false, 
      error: error instanceof Error ? error.message : 'Cancellation failed' 
    }
  }
}
```

## Reactivation Flows

### Reactivate Cancelled Subscription

```typescript
// lib/reactivation-flows.ts
export async function reactivateSubscription(
  userId: string,
  newPlanId?: string
): Promise<{ success: boolean; subscription?: any; error?: string }> {
  
  console.log(`🔄 Reactivating subscription for user ${userId}`)

  try {
    const supabase = createServerUserClient()
    
    // Get cancelled subscription
    const { data: subscription, error } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('user_id', userId)
      .eq('cancel_at_period_end', true)
      .order('updated_at', { ascending: false })
      .limit(1)
      .single()

    if (error || !subscription) {
      return { success: false, error: 'No cancelled subscription found' }
    }

    // Check if still within grace period
    const periodEnd = new Date(subscription.current_period_end)
    const now = new Date()
    
    if (now >= periodEnd) {
      return { 
        success: false, 
        error: 'Subscription has already ended. Please create a new subscription.' 
      }
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    // Reactivate in Stripe
    const stripeSubscription = await stripe.subscriptions.update(subscription.stripe_subscription_id, {
      cancel_at_period_end: false,
      metadata: {
        reactivated_at: new Date().toISOString(),
        reactivation_reason: 'user_requested'
      }
    })

    // Clear cancellation metadata
    const currentMetadata = (subscription.metadata || {}) as any
    const { 
      scheduled_change, 
      cancellation_context, 
      ...remainingMetadata 
    } = currentMetadata

    // Update database
    const { data: reactivatedSub, error: updateError } = await supabase
      .from('subscriptions')
      .update({
        cancel_at_period_end: false,
        status: 'active',
        metadata: {
          ...remainingMetadata,
          reactivation_history: [
            ...(remainingMetadata.reactivation_history || []),
            {
              reactivated_at: new Date().toISOString(),
              was_scheduled_for: scheduled_change?.effectiveAt,
              reactivated_plan: newPlanId || subscription.plan_id
            }
          ]
        },
        updated_at: new Date().toISOString()
      })
      .eq('id', subscription.id)
      .select()
      .single()

    if (updateError) {
      console.error('❌ Database update failed:', updateError)
      throw updateError
    }

    // Track reactivation event
    await trackReactivationEvent(userId, {
      originalPlan: subscription.plan_id,
      reactivatedPlan: newPlanId || subscription.plan_id,
      daysBeforeEnd: Math.ceil((periodEnd.getTime() - now.getTime()) / (1000 * 60 * 60 * 24))
    })

    // Send reactivation confirmation
    await sendReactivationEmail(userId, subscription.plan_id)

    console.log('✅ Subscription reactivated successfully')
    return {
      success: true,
      subscription: reactivatedSub
    }

  } catch (error) {
    console.error('❌ Reactivation failed:', error)
    return { 
      success: false, 
      error: error instanceof Error ? error.message : 'Reactivation failed' 
    }
  }
}
```

## Cancellation UI Components

### Cancellation Flow Modal

```typescript
// components/billing/CancellationFlowModal.tsx
import { useState } from 'react'
import { XMarkIcon } from '@heroicons/react/24/outline'

const cancellationReasons = [
  { id: 'too_expensive', label: 'Too expensive' },
  { id: 'missing_features', label: 'Missing features I need' },
  { id: 'switched_service', label: 'Switched to another service' },
  { id: 'unused', label: 'Not using the service enough' },
  { id: 'temporary', label: 'Temporary pause (planning to return)' },
  { id: 'other', label: 'Other reason' }
]

interface CancellationFlowModalProps {
  isOpen: boolean
  onClose: () => void
  subscription: any
  onConfirm: (reason: string, feedback: string) => Promise<void>
}

export function CancellationFlowModal({
  isOpen,
  onClose,
  subscription,
  onConfirm
}: CancellationFlowModalProps) {
  const [step, setStep] = useState<'reason' | 'feedback' | 'confirm'>('reason')
  const [selectedReason, setSelectedReason] = useState('')
  const [feedback, setFeedback] = useState('')
  const [loading, setLoading] = useState(false)

  const handleReasonSubmit = () => {
    if (selectedReason) {
      setStep('feedback')
    }
  }

  const handleFeedbackSubmit = () => {
    setStep('confirm')
  }

  const handleFinalConfirm = async () => {
    setLoading(true)
    try {
      await onConfirm(selectedReason, feedback)
      onClose()
    } catch (error) {
      console.error('Cancellation failed:', error)
    } finally {
      setLoading(false)
    }
  }

  const resetFlow = () => {
    setStep('reason')
    setSelectedReason('')
    setFeedback('')
  }

  if (!isOpen) return null

  const effectiveDate = new Date(subscription.current_period_end).toLocaleDateString()

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg p-6 max-w-lg w-full mx-4">
        <div className="flex justify-between items-center mb-6">
          <h3 className="text-lg font-semibold">Cancel Subscription</h3>
          <button onClick={onClose} className="text-gray-400 hover:text-gray-600">
            <XMarkIcon className="h-6 w-6" />
          </button>
        </div>

        {step === 'reason' && (
          <div>
            <p className="text-gray-600 mb-4">
              We're sorry to see you go. Could you tell us why you're cancelling?
            </p>
            
            <div className="space-y-2 mb-6">
              {cancellationReasons.map((reason) => (
                <label key={reason.id} className="flex items-center">
                  <input
                    type="radio"
                    name="cancellation_reason"
                    value={reason.id}
                    checked={selectedReason === reason.id}
                    onChange={(e) => setSelectedReason(e.target.value)}
                    className="mr-3"
                  />
                  <span className="text-sm">{reason.label}</span>
                </label>
              ))}
            </div>

            <div className="flex space-x-3">
              <button
                onClick={onClose}
                className="flex-1 px-4 py-2 border border-gray-300 rounded-md text-gray-700 hover:bg-gray-50"
              >
                Keep Subscription
              </button>
              <button
                onClick={handleReasonSubmit}
                disabled={!selectedReason}
                className="flex-1 px-4 py-2 bg-red-600 text-white rounded-md hover:bg-red-700 disabled:opacity-50"
              >
                Continue
              </button>
            </div>
          </div>
        )}

        {step === 'feedback' && (
          <div>
            <p className="text-gray-600 mb-4">
              Thank you for the feedback. Is there anything else you'd like us to know?
            </p>
            
            <textarea
              value={feedback}
              onChange={(e) => setFeedback(e.target.value)}
              placeholder="Optional: Tell us more about your experience..."
              className="w-full p-3 border border-gray-300 rounded-md resize-none h-24 mb-6"
              maxLength={500}
            />

            <div className="flex space-x-3">
              <button
                onClick={() => setStep('reason')}
                className="flex-1 px-4 py-2 border border-gray-300 rounded-md text-gray-700 hover:bg-gray-50"
              >
                Back
              </button>
              <button
                onClick={handleFeedbackSubmit}
                className="flex-1 px-4 py-2 bg-red-600 text-white rounded-md hover:bg-red-700"
              >
                Continue
              </button>
            </div>
          </div>
        )}

        {step === 'confirm' && (
          <div>
            <div className="bg-red-50 border border-red-200 rounded-lg p-4 mb-6">
              <h4 className="font-medium text-red-800 mb-2">
                Confirm Cancellation
              </h4>
              <p className="text-sm text-red-700 mb-2">
                Your subscription will be cancelled at the end of your current billing period.
              </p>
              <ul className="text-sm text-red-700 space-y-1">
                <li>• You'll keep access until <strong>{effectiveDate}</strong></li>
                <li>• No refund will be issued for the current period</li>
                <li>• You can reactivate before {effectiveDate}</li>
                <li>• Your data will be preserved for 90 days</li>
              </ul>
            </div>

            <div className="bg-blue-50 border border-blue-200 rounded-lg p-4 mb-6">
              <h4 className="font-medium text-blue-800 mb-2">
                Before You Cancel
              </h4>
              <p className="text-sm text-blue-700 mb-2">
                Consider these alternatives:
              </p>
              <ul className="text-sm text-blue-700 space-y-1">
                <li>• <button className="underline hover:no-underline" onClick={() => window.location.href = '/pricing'}>Downgrade to a lower plan</button></li>
                <li>• <button className="underline hover:no-underline" onClick={() => window.location.href = '/support'}>Contact support</button> for help</li>
                <li>• Take a break and reactivate later</li>
              </ul>
            </div>

            <div className="flex space-x-3">
              <button
                onClick={resetFlow}
                disabled={loading}
                className="flex-1 px-4 py-2 border border-gray-300 rounded-md text-gray-700 hover:bg-gray-50 disabled:opacity-50"
              >
                Keep Subscription
              </button>
              <button
                onClick={handleFinalConfirm}
                disabled={loading}
                className="flex-1 px-4 py-2 bg-red-600 text-white rounded-md hover:bg-red-700 disabled:opacity-50"
              >
                {loading ? 'Cancelling...' : 'Confirm Cancellation'}
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}
```

### Reactivation Banner

```typescript
// components/billing/ReactivationBanner.tsx
import { useState } from 'react'
import { CheckCircleIcon } from '@heroicons/react/24/outline'

interface ReactivationBannerProps {
  subscription: any
  onReactivate: () => Promise<void>
}

export function ReactivationBanner({ subscription, onReactivate }: ReactivationBannerProps) {
  const [loading, setLoading] = useState(false)

  if (!subscription.cancel_at_period_end) {
    return null
  }

  const effectiveDate = new Date(subscription.current_period_end)
  const daysRemaining = Math.ceil((effectiveDate.getTime() - Date.now()) / (1000 * 60 * 60 * 24))

  const handleReactivate = async () => {
    setLoading(true)
    try {
      await onReactivate()
    } catch (error) {
      console.error('Reactivation failed:', error)
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="bg-orange-50 border border-orange-200 rounded-lg p-4 mb-6">
      <div className="flex items-start">
        <div className="flex-shrink-0">
          <div className="bg-orange-100 rounded-full p-2">
            <CheckCircleIcon className="h-5 w-5 text-orange-600" />
          </div>
        </div>
        
        <div className="ml-3 flex-1">
          <h4 className="font-medium text-orange-800 mb-1">
            Subscription Cancellation Scheduled
          </h4>
          <p className="text-sm text-orange-700 mb-2">
            Your subscription will end on <strong>{effectiveDate.toLocaleDateString()}</strong> 
            ({daysRemaining} days remaining).
          </p>
          <p className="text-sm text-orange-700 mb-3">
            You'll continue to have full access until then.
          </p>
          
          <button
            onClick={handleReactivate}
            disabled={loading}
            className="bg-orange-600 text-white px-4 py-2 rounded-md text-sm font-medium hover:bg-orange-700 disabled:opacity-50"
          >
            {loading ? 'Reactivating...' : 'Reactivate Subscription'}
          </button>
        </div>
      </div>
    </div>
  )
}
```

## Cancellation Analytics

### Cancellation Tracking

```typescript
// lib/cancellation-analytics.ts
export async function trackCancellationEvent(
  userId: string,
  cancellation: {
    plan: string
    reason: string
    feedback?: string
    effectiveDate: string
  }
) {
  try {
    const supabase = createServerServiceRoleClient()
    
    // Store detailed cancellation data
    const { error } = await supabase
      .from('cancellation_events')
      .insert({
        user_id: userId,
        plan_id: cancellation.plan,
        cancellation_reason: cancellation.reason,
        feedback: cancellation.feedback,
        effective_date: cancellation.effectiveDate,
        cancelled_at: new Date().toISOString(),
        
        // Additional context
        metadata: {
          user_tenure: await calculateUserTenure(userId),
          total_revenue: await calculateUserRevenue(userId),
          usage_stats: await getUserUsageStats(userId)
        }
      })

    if (error) {
      console.error('❌ Error tracking cancellation:', error)
      return
    }

    // Send to analytics service
    await analyticsService.track({
      event: 'subscription_cancelled',
      userId,
      properties: {
        plan: cancellation.plan,
        reason: cancellation.reason,
        has_feedback: !!cancellation.feedback,
        days_until_effective: Math.ceil(
          (new Date(cancellation.effectiveDate).getTime() - Date.now()) / (1000 * 60 * 60 * 24)
        )
      }
    })

    console.log('✅ Cancellation event tracked')
  } catch (error) {
    console.error('❌ Error tracking cancellation event:', error)
  }
}

export async function trackReactivationEvent(
  userId: string,
  reactivation: {
    originalPlan: string
    reactivatedPlan: string
    daysBeforeEnd: number
  }
) {
  try {
    const supabase = createServerServiceRoleClient()
    
    await supabase
      .from('reactivation_events')
      .insert({
        user_id: userId,
        original_plan: reactivation.originalPlan,
        reactivated_plan: reactivation.reactivatedPlan,
        days_before_end: reactivation.daysBeforeEnd,
        reactivated_at: new Date().toISOString()
      })

    await analyticsService.track({
      event: 'subscription_reactivated',
      userId,
      properties: reactivation
    })

    console.log('✅ Reactivation event tracked')
  } catch (error) {
    console.error('❌ Error tracking reactivation event:', error)
  }
}

async function calculateUserTenure(userId: string): Promise<number> {
  const supabase = createServerServiceRoleClient()
  
  const { data: user } = await supabase
    .from('users')
    .select('created_at')
    .eq('id', userId)
    .single()

  if (!user) return 0

  return Math.floor((Date.now() - new Date(user.created_at).getTime()) / (1000 * 60 * 60 * 24))
}

async function calculateUserRevenue(userId: string): Promise<number> {
  // Calculate total revenue from this user
  // Implementation depends on your billing history storage
  return 0
}

async function getUserUsageStats(userId: string): Promise<any> {
  // Get usage statistics for analytics
  // Implementation depends on your usage tracking
  return {}
}
```

## Testing Cancellation Flows

### E2E Tests

```typescript
// cypress/e2e/billing/cancellation-flows.cy.ts
describe('Cancellation Flows', () => {
  describe('Standard Cancellation', () => {
    const email = `cancel-test-${Date.now()}@example.com`

    beforeEach(() => {
      cy.seedStarterUser({ email })
      cy.login(email)
    })

    it('should complete cancellation flow with reason and feedback', () => {
      cy.visit('/billing')

      // Open cancellation flow
      cy.get('[data-testid="cancel-subscription-button"]').click()

      // Step 1: Select reason
      cy.get('[data-testid="cancellation-modal"]').should('be.visible')
      cy.get('[data-testid="reason-too-expensive"]').click()
      cy.get('[data-testid="continue-to-feedback"]').click()

      // Step 2: Provide feedback
      cy.get('[data-testid="feedback-textarea"]')
        .type('The pricing is too high for my current needs')
      cy.get('[data-testid="continue-to-confirm"]').click()

      // Step 3: Final confirmation
      cy.get('[data-testid="cancellation-summary"]').should('be.visible')
      cy.get('[data-testid="effective-date"]').should('contain', effectiveDate)

      cy.intercept('POST', '/api/billing/cancel-subscription').as('cancelRequest')
      cy.get('[data-testid="confirm-cancellation"]').click()

      cy.wait('@cancelRequest').then((interception) => {
        expect(interception.response?.statusCode).to.eq(200)
      })

      // Should show cancellation success
      cy.get('[data-testid="cancellation-success"]').should('be.visible')

      // Should show reactivation banner
      cy.reload()
      cy.get('[data-testid="reactivation-banner"]').should('be.visible')
    })
  })

  describe('Reactivation Flow', () => {
    const email = `reactivate-test-${Date.now()}@example.com`

    beforeEach(() => {
      cy.seedStarterUserWithScheduledCancellation({ email })
      cy.login(email)
    })

    it('should allow reactivation within grace period', () => {
      cy.visit('/billing')

      // Should show reactivation banner
      cy.get('[data-testid="reactivation-banner"]').should('be.visible')
      cy.get('[data-testid="days-remaining"]').should('be.visible')

      // Reactivate subscription
      cy.intercept('POST', '/api/billing/reactivate-subscription').as('reactivateRequest')
      cy.get('[data-testid="reactivate-button"]').click()

      cy.wait('@reactivateRequest').then((interception) => {
        expect(interception.response?.statusCode).to.eq(200)
      })

      // Should show reactivation success
      cy.get('[data-testid="reactivation-success"]').should('be.visible')

      // Banner should disappear
      cy.reload()
      cy.get('[data-testid="reactivation-banner"]').should('not.exist')
      cy.get('[data-testid="subscription-active"]').should('be.visible')
    })
  })
})
```

## Retention Strategies

### Cancellation Prevention

```typescript
// lib/retention-strategies.ts
export async function offerRetentionIncentive(
  userId: string,
  cancellationReason: string
): Promise<{ offer?: any; shouldShow: boolean }> {
  
  try {
    const userProfile = await getUserProfile(userId)
    const subscription = await getSubscriptionDetails(userId)
    
    if (!userProfile || !subscription) {
      return { shouldShow: false }
    }

    // Determine appropriate retention offer based on reason
    switch (cancellationReason) {
      case 'too_expensive':
        // Offer discount or downgrade
        const lowerPlan = findLowerPlan(subscription.plan_id)
        if (lowerPlan) {
          return {
            shouldShow: true,
            offer: {
              type: 'downgrade',
              targetPlan: lowerPlan,
              message: `Save money with ${lowerPlan} plan instead of cancelling`,
              action: 'downgrade'
            }
          }
        }
        break

      case 'unused':
        // Offer pause or lower plan
        return {
          shouldShow: true,
          offer: {
            type: 'pause',
            message: 'Pause your subscription for up to 3 months',
            action: 'pause'
          }
        }

      case 'missing_features':
        // Offer higher plan or feature preview
        const higherPlan = findHigherPlan(subscription.plan_id)
        if (higherPlan) {
          return {
            shouldShow: true,
            offer: {
              type: 'upgrade',
              targetPlan: higherPlan,
              message: `Try ${higherPlan} plan with advanced features`,
              action: 'upgrade'
            }
          }
        }
        break

      case 'temporary':
        // Offer subscription pause
        return {
          shouldShow: true,
          offer: {
            type: 'pause',
            message: 'Pause your subscription instead of cancelling',
            action: 'pause'
          }
        }
    }

    return { shouldShow: false }

  } catch (error) {
    console.error('Error determining retention offer:', error)
    return { shouldShow: false }
  }
}

function findLowerPlan(currentPlan: string): string | null {
  const planConfig = getPlanConfig(currentPlan)
  return planConfig?.downgradePlans[0] || null
}

function findHigherPlan(currentPlan: string): string | null {
  const planConfig = getPlanConfig(currentPlan)
  return planConfig?.upgradePlans[0] || null
}
```

## Next Steps

In the next module, we'll cover using Stripe Subscription Schedules effectively for complex timing and phase management.

## Key Takeaways

- Implement customer-friendly cancellation with grace periods
- Collect cancellation feedback for product improvement
- Offer reactivation within grace periods
- Track cancellation and reactivation events for analytics
- Provide retention offers based on cancellation reasons
- Use multi-step cancellation flow to reduce impulsive cancellations
- Handle immediate cancellation for admin/policy scenarios
- Test cancellation and reactivation flows thoroughly
- Store cancellation context for customer support
- Implement proper data retention policies after cancellation
