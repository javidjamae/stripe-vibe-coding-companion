# Annual Billing Implementation

## Overview

This module covers implementing annual billing with proper discounting, handling annual subscription management, and the considerations for annual billing cycles. We'll explore patterns from your codebase for managing annual subscriptions effectively.

## Annual Billing Strategy

Your codebase implements annual billing with significant savings to incentivize longer commitments:

### Pricing Structure Analysis

From your `config/plans.json`:

```json
{
  "starter": {
    "monthly": { "priceCents": 1900 },    // $19/month = $228/year
    "annual": { "priceCents": 12900 }     // $129/year (43% savings)
  },
  "pro": {
    "monthly": { "priceCents": 8900 },    // $89/month = $1,068/year  
    "annual": { "priceCents": 59900 }     // $599/year (44% savings)
  },
  "scale": {
    "monthly": { "priceCents": 34900 },   // $349/month = $4,188/year
    "annual": { "priceCents": 249900 }    // $2,499/year (40% savings)
  }
}
```

**Key Insights**:
- Annual plans offer 40-44% savings
- Significant incentive for annual commitments
- Free plan has no annual option (logical)

## Annual Billing Implementation

### Annual Subscription Creation

```typescript
// lib/annual-billing.ts
export async function createAnnualSubscription(
  userId: string,
  userEmail: string,
  planId: string
): Promise<{ url: string; subscriptionPreview: any }> {
  
  console.log(`💰 Creating annual subscription for ${planId}`)

  // Validate plan supports annual billing
  const annualPriceId = getStripePriceId(planId, 'year')
  if (!annualPriceId) {
    throw new Error(`Plan ${planId} does not support annual billing`)
  }

  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  // Get or create customer
  const customerId = await getOrCreateStripeCustomer(userId, userEmail)

  // Calculate savings to show in checkout
  const savings = calculateAnnualSavings(planId)
  
  // Create checkout session for annual subscription
  const session = await stripe.checkout.sessions.create({
    customer: customerId,
    payment_method_types: ['card'],
    line_items: [{
      price: annualPriceId,
      quantity: 1,
    }],
    mode: 'subscription',
    success_url: `${process.env.APP_URL}/billing?success=true&interval=annual`,
    cancel_url: `${process.env.APP_URL}/billing?canceled=true`,
    metadata: {
      userId: userId,
      planId: planId,
      billingInterval: 'year'
    },
    // Add discount information to checkout
    custom_text: {
      submit: {
        message: savings 
          ? `You're saving $${savings.savingsAmount.toFixed(2)} (${savings.savingsPercent}%) with annual billing!`
          : undefined
      }
    },
    // Enable tax collection for annual subscriptions
    tax_id_collection: { enabled: true },
    automatic_tax: { enabled: true }
  })

  // Preview what the subscription will look like
  const subscriptionPreview = {
    planId,
    interval: 'year',
    price: getPlanPrice(planId, 'year'),
    savings: savings,
    features: {
      computeMinutes: getPlanConfig(planId)?.includedComputeMinutes,
      concurrency: getPlanConfig(planId)?.concurrencyLimit,
      overages: getPlanConfig(planId)?.allowOverages
    }
  }

  return { 
    url: session.url!, 
    subscriptionPreview 
  }
}

export function calculateAnnualSavings(planId: string): {
  monthlyTotal: number
  annualPrice: number
  savingsAmount: number
  savingsPercent: number
} | null {
  const plan = getPlanConfig(planId)
  if (!plan?.monthly || !plan?.annual) return null

  const monthlyAnnual = plan.monthly.priceCents * 12
  const annualPrice = plan.annual.priceCents

  if (monthlyAnnual <= annualPrice) return null

  const savingsAmount = monthlyAnnual - annualPrice
  const savingsPercent = Math.round((savingsAmount / monthlyAnnual) * 100)

  return {
    monthlyTotal: monthlyAnnual / 100,
    annualPrice: annualPrice / 100,
    savingsAmount: savingsAmount / 100,
    savingsPercent
  }
}
```

### Annual Billing Cycle Management

```typescript
// lib/annual-cycle-management.ts
export async function handleAnnualRenewal(subscription: any) {
  console.log('🔄 Processing annual subscription renewal')

  try {
    const supabase = createServerServiceRoleClient()
    
    // Reset monthly usage counters for new annual period
    await resetMonthlyUsageCounters(subscription.user_id)
    
    // Update subscription with new annual period
    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        status: 'active',
        current_period_start: new Date(subscription.current_period_start).toISOString(),
        current_period_end: new Date(subscription.current_period_end).toISOString(),
        metadata: {
          ...subscription.metadata,
          annual_renewal: {
            renewed_at: new Date().toISOString(),
            renewal_count: ((subscription.metadata as any)?.annual_renewal?.renewal_count || 0) + 1
          }
        },
        updated_at: new Date().toISOString()
      })
      .eq('id', subscription.id)

    if (error) {
      console.error('❌ Error updating annual renewal:', error)
      throw error
    }

    // Send annual renewal confirmation
    await sendAnnualRenewalEmail(subscription.user_id, subscription.plan_id)

    console.log('✅ Annual renewal processed successfully')
    return data

  } catch (error) {
    console.error('❌ Annual renewal processing failed:', error)
    throw error
  }
}

async function resetMonthlyUsageCounters(userId: string) {
  const supabase = createServerServiceRoleClient()
  
  // Archive current month's usage
  const { error } = await supabase
    .from('usage_records')
    .update({ 
      archived: true,
      archived_at: new Date().toISOString(),
      archive_reason: 'annual_renewal'
    })
    .eq('user_id', userId)
    .gte('created_at', new Date(Date.now() - 31 * 24 * 60 * 60 * 1000).toISOString()) // Last 31 days

  if (error) {
    console.error('❌ Error archiving usage records:', error)
  } else {
    console.log('✅ Monthly usage counters reset for annual renewal')
  }
}

async function sendAnnualRenewalEmail(userId: string, planId: string) {
  try {
    const user = await getUserProfile(userId)
    const plan = getPlanConfig(planId)
    
    if (!user || !plan) return

    await emailService.send({
      to: user.email,
      template: 'annual_renewal_confirmation',
      data: {
        firstName: user.first_name,
        planName: plan.name,
        renewalDate: new Date().toLocaleDateString(),
        nextRenewalDate: new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toLocaleDateString(),
        annualPrice: plan.annual!.priceCents / 100
      }
    })

    console.log(`✅ Annual renewal email sent to ${user.email}`)
  } catch (error) {
    console.error('❌ Error sending annual renewal email:', error)
  }
}
```

## Annual Billing UI Components

### Annual Savings Display

```typescript
// components/billing/AnnualSavingsDisplay.tsx
import { calculateAnnualSavings } from '@/lib/annual-billing'

interface AnnualSavingsDisplayProps {
  planId: string
  prominent?: boolean
  showBreakdown?: boolean
}

export function AnnualSavingsDisplay({ 
  planId, 
  prominent = false, 
  showBreakdown = false 
}: AnnualSavingsDisplayProps) {
  const savings = calculateAnnualSavings(planId)

  if (!savings) return null

  if (prominent) {
    return (
      <div className="bg-green-50 border border-green-200 rounded-lg p-4">
        <div className="flex items-center">
          <div className="flex-shrink-0">
            <div className="bg-green-500 rounded-full p-1">
              <svg className="h-4 w-4 text-white" fill="currentColor" viewBox="0 0 20 20">
                <path fillRule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clipRule="evenodd" />
              </svg>
            </div>
          </div>
          <div className="ml-3">
            <h3 className="text-sm font-medium text-green-800">
              Save ${savings.savingsAmount.toFixed(0)} with Annual Billing
            </h3>
            <p className="text-sm text-green-700">
              Pay ${savings.annualPrice.toFixed(0)}/year instead of ${savings.monthlyTotal.toFixed(0)}/year
            </p>
          </div>
        </div>
        
        {showBreakdown && (
          <div className="mt-3 text-xs text-green-600">
            <p>Monthly: ${(savings.monthlyTotal / 12).toFixed(0)}/month × 12 = ${savings.monthlyTotal.toFixed(0)}/year</p>
            <p>Annual: ${savings.annualPrice.toFixed(0)}/year (${savings.savingsPercent}% savings)</p>
          </div>
        )}
      </div>
    )
  }

  return (
    <span className="inline-flex items-center px-2 py-1 rounded-full text-xs font-medium bg-green-100 text-green-800">
      Save ${savings.savingsAmount.toFixed(0)} ({savings.savingsPercent}%)
    </span>
  )
}
```

### Annual Billing Dashboard

```typescript
// components/billing/AnnualBillingDashboard.tsx
import { useState, useEffect } from 'react'
import { CalendarIcon, CurrencyDollarIcon } from '@heroicons/react/24/outline'

export function AnnualBillingDashboard({ subscription }: { subscription: any }) {
  const [renewalInfo, setRenewalInfo] = useState<any>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (subscription && subscription.stripe_price_id) {
      loadRenewalInfo()
    }
  }, [subscription])

  const loadRenewalInfo = async () => {
    try {
      // Calculate renewal information
      const currentPeriodEnd = new Date(subscription.current_period_end)
      const daysUntilRenewal = Math.ceil(
        (currentPeriodEnd.getTime() - Date.now()) / (1000 * 60 * 60 * 24)
      )

      const planConfig = getPlanConfig(subscription.plan_id)
      const savings = calculateAnnualSavings(subscription.plan_id)

      setRenewalInfo({
        renewalDate: currentPeriodEnd,
        daysUntilRenewal,
        renewalAmount: planConfig?.annual?.priceCents || 0,
        savings
      })
    } catch (error) {
      console.error('Failed to load renewal info:', error)
    } finally {
      setLoading(false)
    }
  }

  if (loading) {
    return <div className="animate-pulse bg-gray-200 rounded h-24 w-full"></div>
  }

  if (!renewalInfo) return null

  return (
    <div className="bg-white rounded-lg border border-gray-200 p-6">
      <h3 className="text-lg font-medium text-gray-900 mb-4">
        Annual Billing Overview
      </h3>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        {/* Renewal Information */}
        <div className="flex items-start">
          <CalendarIcon className="h-5 w-5 text-gray-400 mt-1" />
          <div className="ml-3">
            <p className="text-sm font-medium text-gray-900">Next Renewal</p>
            <p className="text-sm text-gray-600">
              {renewalInfo.renewalDate.toLocaleDateString()}
            </p>
            <p className="text-xs text-gray-500">
              {renewalInfo.daysUntilRenewal} days remaining
            </p>
          </div>
        </div>

        {/* Savings Information */}
        <div className="flex items-start">
          <CurrencyDollarIcon className="h-5 w-5 text-green-500 mt-1" />
          <div className="ml-3">
            <p className="text-sm font-medium text-gray-900">Annual Savings</p>
            {renewalInfo.savings ? (
              <>
                <p className="text-sm text-green-600 font-medium">
                  ${renewalInfo.savings.savingsAmount.toFixed(0)} saved this year
                </p>
                <p className="text-xs text-gray-500">
                  {renewalInfo.savings.savingsPercent}% vs monthly billing
                </p>
              </>
            ) : (
              <p className="text-sm text-gray-600">No savings data available</p>
            )}
          </div>
        </div>
      </div>

      {/* Renewal Amount */}
      <div className="mt-6 bg-gray-50 rounded-lg p-4">
        <div className="flex justify-between items-center">
          <span className="text-sm text-gray-600">Next renewal amount:</span>
          <span className="text-lg font-medium text-gray-900">
            ${(renewalInfo.renewalAmount / 100).toFixed(2)}
          </span>
        </div>
      </div>

      {/* Progress Bar */}
      <div className="mt-4">
        <div className="flex justify-between text-xs text-gray-600 mb-1">
          <span>Billing period progress</span>
          <span>{Math.round(((365 - renewalInfo.daysUntilRenewal) / 365) * 100)}%</span>
        </div>
        <div className="w-full bg-gray-200 rounded-full h-2">
          <div 
            className="bg-blue-600 h-2 rounded-full transition-all duration-300"
            style={{ 
              width: `${Math.round(((365 - renewalInfo.daysUntilRenewal) / 365) * 100)}%` 
            }}
          ></div>
        </div>
      </div>
    </div>
  )
}
```

### Annual Plan Comparison

```typescript
// components/pricing/AnnualPlanComparison.tsx
export function AnnualPlanComparison({ planId }: { planId: string }) {
  const plan = getPlanConfig(planId)
  const savings = calculateAnnualSavings(planId)

  if (!plan?.monthly || !plan?.annual || !savings) {
    return null
  }

  return (
    <div className="bg-gradient-to-r from-green-50 to-blue-50 rounded-lg p-6 border border-green-200">
      <h3 className="text-lg font-semibold text-gray-900 mb-4">
        Annual vs Monthly Billing
      </h3>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        {/* Monthly Option */}
        <div className="bg-white rounded-lg p-4 border">
          <h4 className="font-medium text-gray-900">Monthly</h4>
          <div className="mt-2">
            <span className="text-2xl font-bold">${plan.monthly.priceCents / 100}</span>
            <span className="text-gray-600">/month</span>
          </div>
          <p className="text-sm text-gray-600 mt-1">
            ${savings.monthlyTotal.toFixed(0)} per year
          </p>
        </div>

        {/* Annual Option */}
        <div className="bg-white rounded-lg p-4 border-2 border-green-500 relative">
          <div className="absolute -top-2 left-1/2 transform -translate-x-1/2">
            <span className="bg-green-500 text-white text-xs px-2 py-1 rounded-full">
              Best Value
            </span>
          </div>
          <h4 className="font-medium text-gray-900">Annual</h4>
          <div className="mt-2">
            <span className="text-2xl font-bold">${plan.annual.priceCents / 100}</span>
            <span className="text-gray-600">/year</span>
          </div>
          <p className="text-sm text-green-600 font-medium mt-1">
            Save ${savings.savingsAmount.toFixed(0)} ({savings.savingsPercent}%)
          </p>
        </div>

        {/* Savings Breakdown */}
        <div className="bg-green-50 rounded-lg p-4 border border-green-200">
          <h4 className="font-medium text-green-800">You Save</h4>
          <div className="mt-2">
            <span className="text-2xl font-bold text-green-600">
              ${savings.savingsAmount.toFixed(0)}
            </span>
          </div>
          <p className="text-sm text-green-600 mt-1">
            {savings.savingsPercent}% discount
          </p>
          <p className="text-xs text-green-600 mt-2">
            Equivalent to {Math.round(savings.savingsAmount / (plan.monthly.priceCents / 100))} months free!
          </p>
        </div>
      </div>

      {/* Features Note */}
      <div className="mt-4 bg-blue-50 rounded-lg p-3">
        <p className="text-sm text-blue-800">
          <strong>Note:</strong> Compute minutes reset monthly even on annual plans. 
          You get {plan.includedComputeMinutes.toLocaleString()} minutes every month for the full year.
        </p>
      </div>
    </div>
  )
}
```

## Annual Subscription Webhooks

### Enhanced Invoice Handling for Annual

```typescript
// Enhanced webhook handler for annual subscriptions
export async function handleAnnualInvoicePaymentSucceeded(invoice: any) {
  console.log('💰 Processing annual invoice payment')

  if (!invoice.subscription) {
    console.log('❌ No subscription ID found')
    return
  }

  try {
    const supabase = createServerServiceRoleClient()
    
    // Determine if this is an annual subscription
    const { data: subscription, error } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('stripe_subscription_id', invoice.subscription)
      .single()

    if (error || !subscription) {
      console.error('❌ Subscription not found:', error)
      return
    }

    const billingInterval = getBillingIntervalFromPrice(subscription.stripe_price_id)
    const isAnnualBilling = billingInterval === 'year'

    // Update subscription status
    const { data: updatedSub, error: updateError } = await supabase
      .from('subscriptions')
      .update({
        status: 'active',
        current_period_start: new Date(invoice.period_start * 1000).toISOString(),
        current_period_end: new Date(invoice.period_end * 1000).toISOString(),
        metadata: {
          ...subscription.metadata,
          last_payment: {
            invoice_id: invoice.id,
            amount: invoice.amount_paid,
            paid_at: new Date().toISOString(),
            billing_interval: billingInterval
          },
          ...(isAnnualBilling && {
            annual_billing: {
              period_start: new Date(invoice.period_start * 1000).toISOString(),
              period_end: new Date(invoice.period_end * 1000).toISOString(),
              total_amount: invoice.amount_paid
            }
          })
        },
        updated_at: new Date().toISOString()
      })
      .eq('id', subscription.id)
      .select()
      .single()

    if (updateError) {
      console.error('❌ Error updating subscription:', updateError)
      return
    }

    // Handle annual-specific processing
    if (isAnnualBilling) {
      await handleAnnualRenewal(updatedSub)
    }

    console.log(`✅ ${isAnnualBilling ? 'Annual' : 'Monthly'} invoice processed successfully`)
    return updatedSub

  } catch (error) {
    console.error('❌ Exception processing annual invoice:', error)
  }
}
```

## Testing Annual Billing

### Unit Tests

```typescript
// __tests__/lib/annual-billing.test.ts
import { calculateAnnualSavings, createAnnualSubscription } from '@/lib/annual-billing'

describe('Annual Billing', () => {
  describe('calculateAnnualSavings', () => {
    it('should calculate savings correctly for starter plan', () => {
      const savings = calculateAnnualSavings('starter')
      
      expect(savings).toBeDefined()
      expect(savings!.monthlyTotal).toBe(228) // $19 × 12
      expect(savings!.annualPrice).toBe(129)
      expect(savings!.savingsAmount).toBe(99) // $228 - $129
      expect(savings!.savingsPercent).toBe(43) // 43% savings
    })

    it('should return null for plans without annual pricing', () => {
      const savings = calculateAnnualSavings('free')
      expect(savings).toBeNull()
    })
  })

  describe('createAnnualSubscription', () => {
    it('should create checkout session with annual pricing', async () => {
      const mockStripe = {
        checkout: {
          sessions: {
            create: jest.fn().mockResolvedValue({
              url: 'https://checkout.stripe.com/pay/test123'
            })
          }
        }
      }

      const result = await createAnnualSubscription(
        'user123',
        'test@example.com',
        'starter'
      )

      expect(result.url).toBe('https://checkout.stripe.com/pay/test123')
      expect(result.subscriptionPreview.interval).toBe('year')
      expect(result.subscriptionPreview.savings).toBeDefined()
    })
  })
})
```

### E2E Tests

```typescript
// cypress/e2e/billing/annual-billing.cy.ts
describe('Annual Billing', () => {
  beforeEach(() => {
    cy.visit('/pricing')
  })

  it('should display annual savings correctly', () => {
    // Switch to annual view
    cy.get('[data-testid="billing-toggle-annual"]').click()

    // Should show savings badges
    cy.get('[data-testid="starter-savings"]').should('contain', 'Save')
    cy.get('[data-testid="pro-savings"]').should('contain', 'Save')
    cy.get('[data-testid="scale-savings"]').should('contain', 'Save')

    // Should show annual prices
    cy.get('[data-testid="starter-price"]').should('contain', '$129/yr')
    cy.get('[data-testid="pro-price"]').should('contain', '$599/yr')
    cy.get('[data-testid="scale-price"]').should('contain', '$2,499/yr')
  })

  it('should create annual subscription', () => {
    cy.login('test@example.com')
    cy.visit('/pricing')

    // Switch to annual and select starter
    cy.get('[data-testid="billing-toggle-annual"]').click()
    cy.get('[data-testid="starter-select-button"]').click()

    // Should redirect to Stripe checkout with annual pricing
    cy.url().should('include', 'checkout.stripe.com')
    
    // Complete checkout with test card
    cy.fillStripeCheckout({
      card: '4242424242424242',
      expiry: '12/34',
      cvc: '123'
    })

    // Should redirect back with success
    cy.url().should('include', '/billing?success=true&interval=annual')
    
    // Should show annual subscription in dashboard
    cy.get('[data-testid="current-plan-interval"]').should('contain', 'Annual')
    cy.get('[data-testid="annual-savings-display"]').should('be.visible')
  })

  it('should show annual billing dashboard for annual subscribers', () => {
    cy.seedStarterAnnualUser({ email: 'annual@example.com' })
    cy.login('annual@example.com')
    cy.visit('/billing')

    // Should show annual billing dashboard
    cy.get('[data-testid="annual-billing-dashboard"]').should('be.visible')
    cy.get('[data-testid="next-renewal-date"]').should('be.visible')
    cy.get('[data-testid="annual-savings-display"]').should('be.visible')
    cy.get('[data-testid="billing-period-progress"]').should('be.visible')
  })
})
```

## Annual Billing Best Practices

### Pricing Strategy

```typescript
// lib/annual-pricing-strategy.ts
export function optimizeAnnualPricing(planId: string): {
  recommendedDiscount: number
  competitiveAnalysis: any
  retentionImpact: any
} {
  const plan = getPlanConfig(planId)
  if (!plan?.monthly || !plan?.annual) {
    throw new Error('Plan does not support annual billing')
  }

  const currentSavings = calculateAnnualSavings(planId)
  if (!currentSavings) {
    throw new Error('Unable to calculate current savings')
  }

  // Industry standard: 15-20% annual discount
  const industryStandard = 20
  const currentDiscount = currentSavings.savingsPercent

  return {
    recommendedDiscount: industryStandard,
    competitiveAnalysis: {
      currentDiscount,
      industryStandard,
      competitive: currentDiscount >= industryStandard
    },
    retentionImpact: {
      // Annual subscribers typically have 2-3x better retention
      estimatedRetentionImprovement: 2.5,
      churnReduction: '60-70%'
    }
  }
}
```

### Annual Renewal Notifications

```typescript
// lib/annual-notifications.ts
export async function scheduleAnnualRenewalNotifications(subscription: any) {
  const renewalDate = new Date(subscription.current_period_end)
  const now = new Date()

  // Schedule notifications at key intervals
  const notifications = [
    { days: 30, template: 'annual_renewal_30_days' },
    { days: 7, template: 'annual_renewal_7_days' },
    { days: 1, template: 'annual_renewal_tomorrow' }
  ]

  for (const notification of notifications) {
    const notificationDate = new Date(renewalDate)
    notificationDate.setDate(notificationDate.getDate() - notification.days)

    if (notificationDate > now) {
      await scheduleEmail({
        userId: subscription.user_id,
        template: notification.template,
        scheduledFor: notificationDate,
        data: {
          renewalDate: renewalDate.toLocaleDateString(),
          renewalAmount: getPlanPrice(subscription.plan_id, 'year') / 100,
          planName: getPlanConfig(subscription.plan_id)?.name
        }
      })
    }
  }
}

async function scheduleEmail(params: {
  userId: string
  template: string
  scheduledFor: Date
  data: any
}) {
  // Implementation depends on your email service
  // Could use a job queue, cron job, or email service scheduling
  console.log(`📧 Scheduled ${params.template} for ${params.scheduledFor.toISOString()}`)
}
```

## Next Steps

In the next module, we'll cover mixed upgrade scenarios like "Pro Annual → Scale Monthly" and other complex cross-plan, cross-interval changes.

## Key Takeaways

- Implement significant annual discounts (40%+) to incentivize longer commitments
- Handle annual renewals with proper usage counter resets
- Display annual savings prominently in pricing and billing UI
- Create annual-specific dashboard components for renewal tracking
- Handle annual subscription webhooks with enhanced metadata
- Schedule renewal notifications at appropriate intervals
- Test annual billing flows thoroughly including renewals
- Consider competitive pricing analysis for annual discounts
- Track annual billing metrics for retention analysis
- Provide clear value proposition for annual commitments
