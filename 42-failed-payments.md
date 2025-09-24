# Failed Payments and Dunning Management

## Overview

This module covers handling failed payments, implementing dunning management strategies, and customer retention flows for payment recovery. We'll explore patterns for gracefully handling payment failures while maintaining customer relationships.

## Payment Failure Overview

### Common Payment Failure Reasons

**Card-Related Failures:**
- Insufficient funds
- Expired cards
- Declined by bank
- Invalid card details

**Account-Related Failures:**
- Frozen accounts
- Spending limits exceeded
- Fraud prevention blocks

**Technical Failures:**
- Network timeouts
- API errors
- Processing delays

## Failed Payment Webhook Handling

### Basic Payment Failure Handler

```typescript
// Enhanced webhook handler for payment failures
export async function handleInvoicePaymentFailed(invoice: any) {
  console.log('💳 Processing invoice.payment_failed')
  console.log('Invoice ID:', invoice.id)
  console.log('Subscription ID:', invoice.subscription)
  console.log('Attempt Count:', invoice.attempt_count)
  console.log('Next Payment Attempt:', invoice.next_payment_attempt)

  if (!invoice.subscription) {
    console.log('❌ No subscription ID found')
    return
  }

  try {
    const supabase = createServerServiceRoleClient()
    
    // Update subscription status to past_due
    const { data: subscription, error } = await supabase
      .from('subscriptions')
      .update({
        status: 'past_due',
        metadata: {
          payment_failure: {
            invoice_id: invoice.id,
            attempt_count: invoice.attempt_count,
            failure_reason: invoice.last_finalization_error?.message || 'Payment failed',
            failed_at: new Date().toISOString(),
            next_attempt: invoice.next_payment_attempt 
              ? new Date(invoice.next_payment_attempt * 1000).toISOString()
              : null
          }
        },
        updated_at: new Date().toISOString()
      })
      .eq('stripe_subscription_id', invoice.subscription)
      .select()
      .single()

    if (error) {
      console.error('❌ Error updating subscription status:', error)
      return
    }

    // Start dunning management process
    await initiateDunningFlow(subscription, invoice)

    console.log('✅ Payment failure processed')
    return subscription

  } catch (error) {
    console.error('❌ Exception in handleInvoicePaymentFailed:', error)
  }
}
```

### Payment Success Recovery Handler

```typescript
// Handle successful payment after failures
export async function handleInvoicePaymentSucceeded(invoice: any) {
  console.log('✅ Processing invoice.payment_succeeded after failure recovery')

  if (!invoice.subscription) return

  try {
    const supabase = createServerServiceRoleClient()

    // Check if this was a recovery from failed payment
    const { data: subscription } = await supabase
      .from('subscriptions')
      .select('status, metadata')
      .eq('stripe_subscription_id', invoice.subscription)
      .single()

    if (subscription?.status === 'past_due') {
      // This is a payment recovery
      const failureMetadata = subscription.metadata?.payment_failure

      await supabase
        .from('subscriptions')
        .update({
          status: 'active',
          metadata: {
            ...subscription.metadata,
            payment_recovery: {
              recovered_at: new Date().toISOString(),
              invoice_id: invoice.id,
              previous_failure: failureMetadata,
              recovery_method: 'automatic_retry'
            },
            payment_failure: null // Clear failure metadata
          },
          updated_at: new Date().toISOString()
        })
        .eq('stripe_subscription_id', invoice.subscription)

      // Send recovery notification
      await sendPaymentRecoveryNotification(subscription.user_id, {
        amount: invoice.amount_paid / 100,
        currency: invoice.currency,
        recoveredAt: new Date().toISOString()
      })

      console.log('✅ Payment recovery processed successfully')
    }

  } catch (error) {
    console.error('❌ Exception in payment recovery handler:', error)
  }
}
```

## Dunning Management Strategy

### Dunning Flow Implementation

```typescript
// lib/dunning/dunning-manager.ts
export class DunningManager {
  async initiateDunningFlow(subscription: any, invoice: any) {
    console.log(`📧 Starting dunning flow for subscription ${subscription.id}`)

    const attemptCount = invoice.attempt_count
    const maxAttempts = 4 // Stripe default

    try {
      // Determine dunning action based on attempt count
      switch (attemptCount) {
        case 1:
          await this.handleFirstFailure(subscription, invoice)
          break

        case 2:
          await this.handleSecondFailure(subscription, invoice)
          break

        case 3:
          await this.handleThirdFailure(subscription, invoice)
          break

        case maxAttempts:
          await this.handleFinalFailure(subscription, invoice)
          break

        default:
          console.log(`Unhandled attempt count: ${attemptCount}`)
      }

    } catch (error) {
      console.error('❌ Dunning flow failed:', error)
    }
  }

  private async handleFirstFailure(subscription: any, invoice: any) {
    console.log('📧 First payment failure - sending gentle reminder')

    // Send gentle reminder email
    await this.sendDunningEmail(subscription.user_id, 'payment_failed_gentle', {
      amount: invoice.amount_due / 100,
      currency: invoice.currency,
      nextAttempt: invoice.next_payment_attempt 
        ? new Date(invoice.next_payment_attempt * 1000).toLocaleDateString()
        : 'in a few days',
      updatePaymentUrl: `${process.env.APP_URL}/billing`
    })

    // Schedule follow-up if no payment method update
    await this.scheduleFollowUp(subscription.user_id, 'payment_reminder', 2) // 2 days
  }

  private async handleSecondFailure(subscription: any, invoice: any) {
    console.log('📧 Second payment failure - sending urgent reminder')

    await this.sendDunningEmail(subscription.user_id, 'payment_failed_urgent', {
      amount: invoice.amount_due / 100,
      currency: invoice.currency,
      attemptCount: invoice.attempt_count,
      nextAttempt: invoice.next_payment_attempt 
        ? new Date(invoice.next_payment_attempt * 1000).toLocaleDateString()
        : 'soon',
      updatePaymentUrl: `${process.env.APP_URL}/billing`,
      supportEmail: process.env.SUPPORT_EMAIL
    })

    // Offer assistance
    await this.scheduleFollowUp(subscription.user_id, 'payment_assistance_offer', 1)
  }

  private async handleThirdFailure(subscription: any, invoice: any) {
    console.log('📧 Third payment failure - sending final warning')

    await this.sendDunningEmail(subscription.user_id, 'payment_final_warning', {
      amount: invoice.amount_due / 100,
      currency: invoice.currency,
      finalAttempt: true,
      updatePaymentUrl: `${process.env.APP_URL}/billing`,
      supportEmail: process.env.SUPPORT_EMAIL,
      planName: this.getPlanName(subscription.plan_id)
    })

    // Escalate to customer success team
    await this.escalateToCustomerSuccess(subscription, invoice)
  }

  private async handleFinalFailure(subscription: any, invoice: any) {
    console.log('🚨 Final payment failure - subscription will be cancelled')

    try {
      const supabase = createServerServiceRoleClient()
      
      // Update subscription status to unpaid
      await supabase
        .from('subscriptions')
        .update({
          status: 'unpaid',
          metadata: {
            ...subscription.metadata,
            final_failure: {
              failed_at: new Date().toISOString(),
              reason: 'max_payment_attempts_reached',
              final_invoice: invoice.id,
              final_amount: invoice.amount_due
            }
          },
          updated_at: new Date().toISOString()
        })
        .eq('id', subscription.id)

      // Send final failure notification
      await this.sendDunningEmail(subscription.user_id, 'subscription_cancelled', {
        amount: invoice.amount_due / 100,
        currency: invoice.currency,
        planName: this.getPlanName(subscription.plan_id),
        reactivateUrl: `${process.env.APP_URL}/billing?action=reactivate`,
        supportEmail: process.env.SUPPORT_EMAIL
      })

      // Offer win-back incentive
      await this.scheduleWinBackCampaign(subscription.user_id)

      console.log('✅ Final payment failure processed')

    } catch (error) {
      console.error('❌ Error handling final payment failure:', error)
    }
  }

  private async sendDunningEmail(
    userId: string,
    template: string,
    data: any
  ) {
    try {
      // Get user details
      const supabase = createServerServiceRoleClient()
      const { data: user } = await supabase.auth.admin.getUserById(userId)
      
      if (!user.user?.email) {
        console.error('No email found for user:', userId)
        return
      }

      // Send email (integrate with your email service)
      await sendEmail({
        to: user.user.email,
        template: template,
        data: {
          firstName: user.user.user_metadata?.first_name || 'Valued Customer',
          ...data
        }
      })

      console.log(`📧 Sent ${template} email to ${user.user.email}`)

    } catch (error) {
      console.error('Failed to send dunning email:', error)
    }
  }

  private async scheduleFollowUp(
    userId: string,
    action: string,
    delayDays: number
  ) {
    const supabase = createServerServiceRoleClient()
    
    const scheduledFor = new Date(Date.now() + delayDays * 24 * 60 * 60 * 1000)

    await supabase
      .from('scheduled_actions')
      .insert({
        user_id: userId,
        action_type: action,
        scheduled_for: scheduledFor.toISOString(),
        status: 'pending',
        metadata: {
          created_by: 'dunning_manager',
          delay_days: delayDays
        }
      })

    console.log(`📅 Scheduled ${action} for ${scheduledFor.toISOString()}`)
  }

  private async escalateToCustomerSuccess(subscription: any, invoice: any) {
    const supabase = createServerServiceRoleClient()

    await supabase
      .from('customer_success_queue')
      .insert({
        user_id: subscription.user_id,
        priority: 'high',
        reason: 'payment_failure_escalation',
        context: {
          subscription_id: subscription.id,
          invoice_id: invoice.id,
          attempt_count: invoice.attempt_count,
          amount_due: invoice.amount_due / 100,
          plan_id: subscription.plan_id
        },
        created_at: new Date().toISOString()
      })

    console.log(`🎯 Escalated payment failure to customer success team`)
  }

  private async scheduleWinBackCampaign(userId: string) {
    // Schedule win-back email series
    const winBackSchedule = [
      { template: 'winback_immediate', delayDays: 1 },
      { template: 'winback_discount_offer', delayDays: 7 },
      { template: 'winback_final_offer', delayDays: 30 }
    ]

    for (const email of winBackSchedule) {
      await this.scheduleFollowUp(userId, email.template, email.delayDays)
    }

    console.log(`📈 Scheduled win-back campaign for user ${userId}`)
  }

  private getPlanName(planId: string): string {
    const planConfig = getPlanConfig(planId)
    return planConfig?.name || planId
  }
}
```

## Payment Recovery UI

### Payment Failure Banner

```typescript
// components/billing/PaymentFailureBanner.tsx
import { useState } from 'react'
import { ExclamationTriangleIcon, CreditCardIcon } from '@heroicons/react/24/outline'

interface PaymentFailureBannerProps {
  subscription: any
  onRecoverySuccess: () => void
}

export function PaymentFailureBanner({ subscription, onRecoverySuccess }: PaymentFailureBannerProps) {
  const [retrying, setRetrying] = useState(false)

  if (subscription?.status !== 'past_due' && subscription?.status !== 'unpaid') {
    return null
  }

  const paymentFailure = subscription.metadata?.payment_failure
  const attemptCount = paymentFailure?.attempt_count || 0
  const nextAttempt = paymentFailure?.next_attempt
  const failureReason = paymentFailure?.failure_reason

  const handleUpdatePayment = async () => {
    try {
      // Redirect to Customer Portal for payment method update
      const response = await fetch('/api/billing/create-portal-session', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ userId: subscription.user_id })
      })

      if (response.ok) {
        const { url } = await response.json()
        window.location.href = url
      }
    } catch (error) {
      console.error('Failed to open payment portal:', error)
    }
  }

  const handleRetryPayment = async () => {
    setRetrying(true)
    try {
      const response = await fetch('/api/billing/retry-payment', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' }
      })

      if (response.ok) {
        onRecoverySuccess()
      } else {
        const data = await response.json()
        alert(data.error || 'Payment retry failed')
      }
    } catch (error) {
      console.error('Payment retry failed:', error)
      alert('Failed to retry payment. Please try again.')
    } finally {
      setRetrying(false)
    }
  }

  const getSeverityStyle = () => {
    if (attemptCount >= 3) {
      return 'bg-red-50 border-red-200'
    } else if (attemptCount >= 2) {
      return 'bg-orange-50 border-orange-200'
    } else {
      return 'bg-yellow-50 border-yellow-200'
    }
  }

  const getTextStyle = () => {
    if (attemptCount >= 3) {
      return 'text-red-800'
    } else if (attemptCount >= 2) {
      return 'text-orange-800'
    } else {
      return 'text-yellow-800'
    }
  }

  return (
    <div className={`rounded-lg p-4 mb-6 border ${getSeverityStyle()}`}>
      <div className="flex items-start">
        <ExclamationTriangleIcon className={`h-5 w-5 mt-0.5 mr-3 ${
          attemptCount >= 3 ? 'text-red-400' : 
          attemptCount >= 2 ? 'text-orange-400' : 'text-yellow-400'
        }`} />
        
        <div className="flex-1">
          <h4 className={`font-medium mb-1 ${getTextStyle()}`}>
            {attemptCount >= 3 ? 'Payment Failed - Action Required' :
             attemptCount >= 2 ? 'Payment Issue - Please Update' :
             'Payment Failed - We\'ll Retry Soon'}
          </h4>
          
          <p className={`text-sm mb-3 ${getTextStyle()}`}>
            Your payment could not be processed.
            {attemptCount > 1 && ` (Attempt ${attemptCount} of 4)`}
            {attemptCount >= 3 && ' Your subscription may be cancelled if not resolved.'}
          </p>
          
          {failureReason && (
            <p className={`text-sm mb-3 ${getTextStyle()}`}>
              <strong>Reason:</strong> {failureReason}
            </p>
          )}

          {nextAttempt && attemptCount < 4 && (
            <p className={`text-sm mb-3 ${getTextStyle()}`}>
              Next automatic retry: {new Date(nextAttempt).toLocaleDateString()}
            </p>
          )}

          <div className="flex space-x-3">
            <button
              onClick={handleUpdatePayment}
              className={`px-4 py-2 rounded-md text-sm font-medium text-white ${
                attemptCount >= 3 ? 'bg-red-600 hover:bg-red-700' :
                attemptCount >= 2 ? 'bg-orange-600 hover:bg-orange-700' :
                'bg-yellow-600 hover:bg-yellow-700'
              }`}
            >
              <CreditCardIcon className="h-4 w-4 mr-2 inline" />
              Update Payment Method
            </button>
            
            {attemptCount < 4 && (
              <button
                onClick={handleRetryPayment}
                disabled={retrying}
                className="px-4 py-2 bg-gray-600 text-white rounded-md text-sm hover:bg-gray-700 disabled:opacity-50"
              >
                {retrying ? 'Retrying...' : 'Retry Now'}
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}
```

## Customer Communication Strategy

### Email Templates for Payment Failures

```typescript
// lib/email/payment-failure-templates.ts
export const PaymentFailureTemplates = {
  payment_failed_gentle: {
    subject: 'Payment Update Needed - {{planName}} Subscription',
    html: `
      <h2>Hi {{firstName}},</h2>
      
      <p>We had trouble processing your payment for your {{planName}} subscription.</p>
      
      <p><strong>Amount:</strong> ${{amount}} {{currency}}</p>
      <p><strong>Next attempt:</strong> {{nextAttempt}}</p>
      
      <p>This sometimes happens when:</p>
      <ul>
        <li>Your card has expired</li>
        <li>Your bank declined the payment</li>
        <li>Your billing address has changed</li>
      </ul>
      
      <p>No worries! You can update your payment method here:</p>
      <a href="{{updatePaymentUrl}}" style="background: #3B82F6; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px; display: inline-block;">
        Update Payment Method
      </a>
      
      <p>Your subscription remains active, and we'll automatically retry the payment {{nextAttempt}}.</p>
      
      <p>Questions? Just reply to this email.</p>
      
      <p>Thanks,<br>The Team</p>
    `,
    text: `
      Hi {{firstName}},
      
      We had trouble processing your payment for your {{planName}} subscription.
      
      Amount: ${{amount}} {{currency}}
      Next attempt: {{nextAttempt}}
      
      Please update your payment method: {{updatePaymentUrl}}
      
      Your subscription remains active for now.
      
      Questions? Just reply to this email.
      
      Thanks,
      The Team
    `
  },

  payment_failed_urgent: {
    subject: 'Urgent: Payment Required - {{planName}} Subscription',
    html: `
      <h2>Hi {{firstName}},</h2>
      
      <p><strong>This is attempt {{attemptCount}} of 4.</strong> We still haven't been able to process your payment.</p>
      
      <p><strong>Amount due:</strong> ${{amount}} {{currency}}</p>
      
      <p>To avoid any interruption to your service, please update your payment method immediately:</p>
      
      <a href="{{updatePaymentUrl}}" style="background: #DC2626; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px; display: inline-block;">
        Update Payment Method Now
      </a>
      
      <p>Need help? Contact our support team at {{supportEmail}} - we're here to help!</p>
      
      <p>Thanks,<br>The Team</p>
    `
  },

  payment_final_warning: {
    subject: 'Final Notice: Update Payment Method to Keep Your {{planName}} Subscription',
    html: `
      <h2>Hi {{firstName}},</h2>
      
      <p><strong style="color: #DC2626;">This is your final notice.</strong> We've been unable to process your payment after multiple attempts.</p>
      
      <p><strong>Your {{planName}} subscription will be cancelled if we don't receive payment within 24 hours.</strong></p>
      
      <p><strong>Amount due:</strong> ${{amount}} {{currency}}</p>
      
      <p>Update your payment method now to keep your subscription active:</p>
      
      <a href="{{updatePaymentUrl}}" style="background: #DC2626; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px; display: inline-block;">
        Save My Subscription
      </a>
      
      <p>If you're experiencing financial difficulties, please reach out to us at {{supportEmail}}. We may be able to work out a solution.</p>
      
      <p>We really don't want to see you go!</p>
      
      <p>The Team</p>
    `
  },

  subscription_cancelled: {
    subject: 'Your {{planName}} Subscription Has Been Cancelled',
    html: `
      <h2>Hi {{firstName}},</h2>
      
      <p>We're sorry to see you go. Your {{planName}} subscription has been cancelled due to payment failure.</p>
      
      <p><strong>Outstanding amount:</strong> ${{amount}} {{currency}}</p>
      
      <p>You can reactivate your subscription at any time by updating your payment method:</p>
      
      <a href="{{reactivateUrl}}" style="background: #3B82F6; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px; display: inline-block;">
        Reactivate Subscription
      </a>
      
      <p>We'd love to have you back. If there's anything we can do to improve our service, please let us know at {{supportEmail}}.</p>
      
      <p>Thanks for being a customer!</p>
      
      <p>The Team</p>
    `
  }
}
```

## Payment Recovery APIs

### Manual Payment Retry

```typescript
// app/api/billing/retry-payment/route.ts
export async function POST(request: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    // Get user's subscription
    const subscription = await getSubscriptionDetails(user.id)
    if (!subscription?.stripe_subscription_id) {
      return new Response(
      JSON.stringify({ error: 'No subscription found' ),
      { status: 404 })
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    // Get latest unpaid invoice
    const invoices = await stripe.invoices.list({
      subscription: subscription.stripe_subscription_id,
      status: 'open',
      limit: 1
    })

    if (invoices.data.length === 0) {
      return new Response(
      JSON.stringify({ error: 'No unpaid invoices found' ),
      { status: 404 })
    }

    const invoice = invoices.data[0]

    // Attempt to pay the invoice
    try {
      const paidInvoice = await stripe.invoices.pay(invoice.id)

      if (paidInvoice.status === 'paid') {
        // Update subscription status
        await supabase
          .from('subscriptions')
          .update({
            status: 'active',
            metadata: {
              payment_recovery: {
                recovered_at: new Date().toISOString(),
                invoice_id: invoice.id,
                recovery_method: 'manual_retry'
              }
            },
            updated_at: new Date().toISOString()
          })
          .eq('stripe_subscription_id', subscription.stripe_subscription_id)

        return new Response(
      JSON.stringify({
          success: true,
          message: 'Payment processed successfully',
          invoice: {
            id: paidInvoice.id,
            amount: paidInvoice.amount_paid / 100,
            currency: paidInvoice.currency
          }
        })
      }

      return new Response(
      JSON.stringify({ 
        error: 'Payment failed again',
        details: 'The payment method was declined' 
      ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })

    } catch (paymentError) {
      console.error('Manual payment retry failed:', paymentError)
      
      if (paymentError instanceof Stripe.errors.StripeCardError) {
        return new Response(
      JSON.stringify({ 
          error: 'Payment failed',
          details: paymentError.message,
          code: paymentError.code 
        ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
      }

      return new Response(
      JSON.stringify({ 
        error: 'Payment processing failed',
        details: 'Please update your payment method and try again'
      ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
    }

  } catch (error) {
    console.error('Payment retry error:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to retry payment' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

### Subscription Reactivation

```typescript
// app/api/billing/reactivate/route.ts
export async function POST(request: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    const { paymentMethodId } = await request.json()

    // Get cancelled subscription
    const { data: subscription } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('user_id', user.id)
      .eq('status', 'unpaid')
      .order('updated_at', { ascending: false })
      .limit(1)
      .single()

    if (!subscription) {
      return new Response(
      JSON.stringify({ error: 'No cancelled subscription found' ),
      { status: 404 })
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    // Update payment method if provided
    if (paymentMethodId && subscription.stripe_customer_id) {
      await stripe.customers.update(subscription.stripe_customer_id, {
        invoice_settings: {
          default_payment_method: paymentMethodId
        }
      })
    }

    // Reactivate subscription
    if (subscription.stripe_subscription_id) {
      // Try to reactivate existing subscription
      try {
        const reactivated = await stripe.subscriptions.update(subscription.stripe_subscription_id, {
          cancel_at_period_end: false,
          // Clear any cancellation
        })

        // Update database
        await supabase
          .from('subscriptions')
          .update({
            status: reactivated.status,
            cancel_at_period_end: false,
            metadata: {
              reactivation: {
                reactivated_at: new Date().toISOString(),
                reactivated_by: user.id,
                previous_status: subscription.status
              }
            },
            updated_at: new Date().toISOString()
          })
          .eq('id', subscription.id)

        return new Response(
      JSON.stringify({
          success: true,
          message: 'Subscription reactivated successfully',
          subscription: {
            id: reactivated.id,
            status: reactivated.status,
            planId: subscription.plan_id
          }
        })

      } catch (stripeError) {
        // If reactivation fails, create new subscription
        console.log('Reactivation failed, creating new subscription:', stripeError.message)
      }
    }

    // Create new subscription if reactivation failed or no Stripe subscription exists
    const priceId = getStripePriceId(subscription.plan_id, 'month')
    if (!priceId) {
      return new Response(
      JSON.stringify({ error: 'Invalid plan configuration' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    const newSubscription = await stripe.subscriptions.create({
      customer: subscription.stripe_customer_id,
      items: [{ price: priceId }],
      payment_behavior: 'error_if_incomplete',
      metadata: {
        userId: user.id,
        planId: subscription.plan_id,
        reactivation: 'true',
        previous_subscription: subscription.stripe_subscription_id
      }
    })

    // Update database with new subscription
    await supabase
      .from('subscriptions')
      .update({
        stripe_subscription_id: newSubscription.id,
        status: newSubscription.status,
        current_period_start: new Date(newSubscription.current_period_start * 1000).toISOString(),
        current_period_end: new Date(newSubscription.current_period_end * 1000).toISOString(),
        cancel_at_period_end: false,
        metadata: {
          reactivation: {
            reactivated_at: new Date().toISOString(),
            reactivated_by: user.id,
            new_subscription: true
          }
        },
        updated_at: new Date().toISOString()
      })
      .eq('id', subscription.id)

    return new Response(
      JSON.stringify({
      success: true,
      message: 'Subscription reactivated with new billing cycle',
      subscription: {
        id: newSubscription.id,
        status: newSubscription.status,
        planId: subscription.plan_id
      }
    })

  } catch (error) {
    console.error('Subscription reactivation failed:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to reactivate subscription' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Win-Back Campaigns

### Automated Win-Back Flow

```typescript
// lib/retention/win-back-campaigns.ts
export class WinBackCampaign {
  async startWinBackFlow(userId: string, cancelledSubscription: any) {
    console.log(`📈 Starting win-back flow for user ${userId}`)

    try {
      // Create win-back campaign record
      const supabase = createServerServiceRoleClient()
      
      const { data: campaign, error } = await supabase
        .from('win_back_campaigns')
        .insert({
          user_id: userId,
          cancelled_subscription_id: cancelledSubscription.id,
          cancelled_plan: cancelledSubscription.plan_id,
          status: 'active',
          started_at: new Date().toISOString()
        })
        .select()
        .single()

      if (error) throw error

      // Schedule win-back emails
      await this.scheduleWinBackEmails(userId, campaign.id, cancelledSubscription.plan_id)

      // Create limited-time discount offer
      await this.createWinBackDiscount(userId, cancelledSubscription.plan_id)

      console.log(`✅ Win-back campaign started for user ${userId}`)

    } catch (error) {
      console.error('Failed to start win-back campaign:', error)
    }
  }

  private async scheduleWinBackEmails(userId: string, campaignId: string, cancelledPlan: string) {
    const emailSchedule = [
      {
        template: 'winback_immediate',
        delayDays: 1,
        subject: 'We\'re sorry to see you go'
      },
      {
        template: 'winback_value_reminder',
        delayDays: 7,
        subject: 'Remember what you\'re missing?'
      },
      {
        template: 'winback_discount_offer',
        delayDays: 14,
        subject: '50% off to come back'
      },
      {
        template: 'winback_final_offer',
        delayDays: 30,
        subject: 'Last chance - we miss you!'
      }
    ]

    const supabase = createServerServiceRoleClient()

    for (const email of emailSchedule) {
      const scheduledFor = new Date(Date.now() + email.delayDays * 24 * 60 * 60 * 1000)

      await supabase
        .from('scheduled_emails')
        .insert({
          user_id: userId,
          campaign_id: campaignId,
          template: email.template,
          subject: email.subject,
          scheduled_for: scheduledFor.toISOString(),
          status: 'pending',
          metadata: {
            cancelled_plan: cancelledPlan,
            delay_days: email.delayDays
          }
        })
    }

    console.log(`📧 Scheduled ${emailSchedule.length} win-back emails`)
  }

  private async createWinBackDiscount(userId: string, cancelledPlan: string) {
    try {
      const couponManager = new CouponManager()
      
      // Create personalized discount code
      const discountCode = `WINBACK-${userId.substring(0, 8).toUpperCase()}`
      
      const coupon = await couponManager.createPercentageCoupon(
        discountCode,
        50, // 50% off
        'repeating',
        {
          durationInMonths: 3, // 3 months at 50% off
          maxRedemptions: 1,
          expiresAt: new Date(Date.now() + 60 * 24 * 60 * 60 * 1000), // 60 days
          applicablePlans: [cancelledPlan]
        }
      )

      console.log(`💰 Created win-back discount: ${discountCode}`)

      return {
        code: discountCode,
        discount: 50,
        expiresAt: new Date(Date.now() + 60 * 24 * 60 * 60 * 1000)
      }

    } catch (error) {
      console.error('Failed to create win-back discount:', error)
      return null
    }
  }

  async trackWinBackSuccess(userId: string, newSubscriptionId: string) {
    const supabase = createServerServiceRoleClient()

    try {
      // Update win-back campaign status
      await supabase
        .from('win_back_campaigns')
        .update({
          status: 'successful',
          completed_at: new Date().toISOString(),
          new_subscription_id: newSubscriptionId
        })
        .eq('user_id', userId)
        .eq('status', 'active')

      // Cancel remaining scheduled emails
      await supabase
        .from('scheduled_emails')
        .update({ status: 'cancelled' })
        .eq('user_id', userId)
        .eq('status', 'pending')

      console.log(`🎉 Win-back campaign successful for user ${userId}`)

    } catch (error) {
      console.error('Failed to track win-back success:', error)
    }
  }
}
```

## Testing Payment Failures

### Payment Failure Simulation

```typescript
// cypress/tasks/payment-failure-simulation.ts
export async function simulatePaymentFailure(email: string, attemptCount: number = 1) {
  console.log(`💳 Simulating payment failure for ${email} (attempt ${attemptCount})`)

  try {
    // Get user's subscription
    const user = await getUserByEmail(email)
    const { data: subscription } = await supabaseAdmin
      .from('subscriptions')
      .select('stripe_subscription_id')
      .eq('user_id', user.id)
      .single()

    if (!subscription?.stripe_subscription_id) {
      throw new Error('No subscription found')
    }

    // Create mock invoice payment failed event
    const mockInvoice = {
      id: `in_test_failed_${Date.now()}`,
      subscription: subscription.stripe_subscription_id,
      amount_due: 1900,
      currency: 'usd',
      status: 'open',
      attempt_count: attemptCount,
      next_payment_attempt: Math.floor((Date.now() + 3 * 24 * 60 * 60 * 1000) / 1000), // 3 days
      last_finalization_error: {
        message: 'Your card was declined.',
        code: 'card_declined'
      }
    }

    // Call webhook handler directly
    const { handleInvoicePaymentFailed } = await import(
      '../../../app/api/webhooks/stripe/handlers'
    )
    
    await handleInvoicePaymentFailed(mockInvoice)

    console.log(`✅ Payment failure simulation completed`)
    return { ok: true }

  } catch (error) {
    console.error('❌ Payment failure simulation failed:', error)
    return { ok: false, error: error.message }
  }
}
```

### E2E Payment Recovery Tests

```typescript
// cypress/e2e/billing/payment-recovery.cy.ts
describe('Payment Recovery Flow', () => {
  const email = `payment-recovery-${Date.now()}@example.com`

  beforeEach(() => {
    cy.task('seedStarterUserWithStripeSubscription', { email })
  })

  it('should show payment failure banner for past_due subscription', () => {
    // Simulate payment failure
    cy.task('simulatePaymentFailure', { email, attemptCount: 1 })

    cy.login(email)
    cy.visit('/billing')

    // Should show payment failure banner
    cy.get('[data-testid="payment-failure-banner"]').should('be.visible')
    cy.get('[data-testid="payment-failure-banner"]').should('contain', 'Payment Failed')
    cy.get('[data-testid="payment-failure-banner"]').should('contain', 'Attempt 1 of 4')

    // Should show update payment button
    cy.get('[data-testid="update-payment-button"]').should('be.visible')
  })

  it('should escalate messaging for multiple failures', () => {
    // Simulate multiple payment failures
    cy.task('simulatePaymentFailure', { email, attemptCount: 3 })

    cy.login(email)
    cy.visit('/billing')

    // Should show urgent messaging
    cy.get('[data-testid="payment-failure-banner"]').should('contain', 'Action Required')
    cy.get('[data-testid="payment-failure-banner"]').should('contain', 'Attempt 3 of 4')
    cy.get('[data-testid="payment-failure-banner"]').should('contain', 'may be cancelled')
  })

  it('should allow manual payment retry', () => {
    cy.task('simulatePaymentFailure', { email, attemptCount: 2 })

    cy.login(email)
    cy.visit('/billing')

    // Intercept retry payment API
    cy.intercept('POST', '/api/billing/retry-payment').as('retryPayment')

    // Click retry payment button
    cy.get('[data-testid="retry-payment-button"]').click()

    cy.wait('@retryPayment').then((interception) => {
      // Should attempt payment retry
      expect(interception.response?.statusCode).to.be.oneOf([200, 400])
    })
  })
})
```

## Alternative: Simple Payment Failure Handling

For basic payment failure handling without complex dunning:

### Simplified Failure Notification

```typescript
// lib/payments/simple-failure-handler.ts (Alternative approach)
export class SimpleFailureHandler {
  async handlePaymentFailure(subscription: any, invoice: any) {
    console.log(`💳 Simple payment failure handling for ${subscription.id}`)

    try {
      // Update subscription status
      const supabase = createServerServiceRoleClient()
      await supabase
        .from('subscriptions')
        .update({
          status: 'past_due',
          updated_at: new Date().toISOString()
        })
        .eq('stripe_subscription_id', invoice.subscription)

      // Send single notification email
      await this.sendFailureNotification(subscription.user_id, {
        amount: invoice.amount_due / 100,
        currency: invoice.currency,
        updateUrl: `${process.env.APP_URL}/billing`
      })

      console.log('✅ Simple payment failure handled')

    } catch (error) {
      console.error('Simple failure handling failed:', error)
    }
  }

  private async sendFailureNotification(userId: string, data: any) {
    const { data: user } = await supabaseAdmin.auth.admin.getUserById(userId)
    
    if (user.user?.email) {
      await sendEmail({
        to: user.user.email,
        subject: 'Payment Update Needed',
        template: 'simple_payment_failure',
        data
      })
    }
  }
}
```

## Next Steps

In the next module, we'll cover PCI compliance, data retention, and privacy considerations for billing systems.

## Key Takeaways

- **Implement graduated dunning flows** with escalating urgency
- **Update subscription status** immediately when payments fail
- **Provide clear recovery options** for customers with payment issues
- **Use customer-friendly messaging** that explains the situation
- **Offer multiple recovery methods** (retry, update payment method, contact support)
- **Track payment failure patterns** to identify systemic issues
- **Implement win-back campaigns** for cancelled customers
- **Test payment failure scenarios** thoroughly including edge cases
- **Monitor dunning effectiveness** and adjust messaging based on results
- **Provide excellent customer support** during payment difficulties
