# Coupons and Promotional Pricing

## Overview

This module covers implementing coupons, discounts, and promotional pricing using Stripe's promotion codes and coupons. We'll explore discount strategies, implementation patterns, and how to integrate promotional pricing into your existing billing system.

## Coupon Strategy Overview

### Types of Discounts

**Percentage Discounts:**
- 20% off first month
- 50% off annual plans
- 10% off for students

**Fixed Amount Discounts:**
- $10 off first month
- $100 off annual plans
- Free month credit

**Duration-Based Discounts:**
- First month free
- 3 months at 50% off
- Forever discount for early adopters

## Stripe Coupon Implementation

### Creating Coupons

```typescript
// lib/promotions/coupon-management.ts
export class CouponManager {
  private stripe: Stripe

  constructor() {
    this.stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })
  }

  async createPercentageCoupon(
    code: string,
    percentOff: number,
    duration: 'once' | 'repeating' | 'forever',
    options: {
      durationInMonths?: number
      maxRedemptions?: number
      expiresAt?: Date
      minimumAmount?: number
      applicablePlans?: string[]
    } = {}
  ) {
    try {
      // Create the coupon
      const coupon = await this.stripe.coupons.create({
        percent_off: percentOff,
        duration: duration,
        duration_in_months: options.durationInMonths,
        max_redemptions: options.maxRedemptions,
        redeem_by: options.expiresAt ? Math.floor(options.expiresAt.getTime() / 1000) : undefined,
        currency: 'usd',
        metadata: {
          code: code,
          applicable_plans: options.applicablePlans?.join(',') || '',
          created_by: 'system'
        }
      })

      // Create promotion code
      const promotionCode = await this.stripe.promotionCodes.create({
        coupon: coupon.id,
        code: code.toUpperCase(),
        active: true,
        metadata: {
          created_by: 'system',
          campaign: 'general'
        }
      })

      console.log(`✅ Created percentage coupon: ${code} (${percentOff}% off)`)

      return {
        couponId: coupon.id,
        promotionCodeId: promotionCode.id,
        code: promotionCode.code
      }

    } catch (error) {
      console.error('Failed to create percentage coupon:', error)
      throw error
    }
  }

  async createFixedAmountCoupon(
    code: string,
    amountOff: number, // in cents
    currency: string = 'usd',
    duration: 'once' | 'repeating' | 'forever',
    options: {
      durationInMonths?: number
      maxRedemptions?: number
      expiresAt?: Date
      applicablePlans?: string[]
    } = {}
  ) {
    try {
      const coupon = await this.stripe.coupons.create({
        amount_off: amountOff,
        currency: currency,
        duration: duration,
        duration_in_months: options.durationInMonths,
        max_redemptions: options.maxRedemptions,
        redeem_by: options.expiresAt ? Math.floor(options.expiresAt.getTime() / 1000) : undefined,
        metadata: {
          code: code,
          applicable_plans: options.applicablePlans?.join(',') || '',
          created_by: 'system'
        }
      })

      const promotionCode = await this.stripe.promotionCodes.create({
        coupon: coupon.id,
        code: code.toUpperCase(),
        active: true
      })

      console.log(`✅ Created fixed amount coupon: ${code} ($${amountOff/100} off)`)

      return {
        couponId: coupon.id,
        promotionCodeId: promotionCode.id,
        code: promotionCode.code
      }

    } catch (error) {
      console.error('Failed to create fixed amount coupon:', error)
      throw error
    }
  }

  async validateCouponCode(code: string): Promise<{
    valid: boolean
    coupon?: any
    promotionCode?: any
    error?: string
  }> {
    try {
      // Find promotion code
      const promotionCodes = await this.stripe.promotionCodes.list({
        code: code.toUpperCase(),
        active: true,
        limit: 1
      })

      if (promotionCodes.data.length === 0) {
        return { valid: false, error: 'Coupon code not found' }
      }

      const promotionCode = promotionCodes.data[0]
      const coupon = await this.stripe.coupons.retrieve(promotionCode.coupon as string)

      // Check if coupon is still valid
      if (!coupon.valid) {
        return { valid: false, error: 'Coupon is no longer valid' }
      }

      // Check expiration
      if (coupon.redeem_by && coupon.redeem_by < Math.floor(Date.now() / 1000)) {
        return { valid: false, error: 'Coupon has expired' }
      }

      // Check redemption limit
      if (coupon.max_redemptions && coupon.times_redeemed >= coupon.max_redemptions) {
        return { valid: false, error: 'Coupon redemption limit reached' }
      }

      return {
        valid: true,
        coupon,
        promotionCode
      }

    } catch (error) {
      console.error('Coupon validation failed:', error)
      return { valid: false, error: 'Validation failed' }
    }
  }
}
```

## Checkout Integration with Coupons

### Coupon-Enabled Checkout Sessions

```typescript
// Enhanced checkout session creation with coupon support
export async function createCheckoutSessionWithCoupon(
  userId: string,
  userEmail: string,
  planId: string,
  successUrl: string,
  cancelUrl: string,
  billingInterval: 'month' | 'year' = 'month',
  couponCode?: string
) {
  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  // Get plan details
  const priceId = getStripePriceId(planId, billingInterval)
  if (!priceId) {
    throw new Error('Invalid plan or billing interval')
  }

  // Validate coupon if provided
  let discounts: any[] = []
  if (couponCode) {
    const couponManager = new CouponManager()
    const validation = await couponManager.validateCouponCode(couponCode)
    
    if (!validation.valid) {
      throw new Error(validation.error || 'Invalid coupon code')
    }

    // Check if coupon applies to this plan
    const applicablePlans = validation.coupon?.metadata?.applicable_plans?.split(',') || []
    if (applicablePlans.length > 0 && !applicablePlans.includes(planId)) {
      throw new Error(`Coupon is not valid for ${planId} plan`)
    }

    discounts = [{ promotion_code: validation.promotionCode.id }]
  }

  // Get or create customer
  const customer = await getOrCreateStripeCustomer(userId, userEmail)

  // Create checkout session with discount
  const session = await stripe.checkout.sessions.create({
    customer: customer.id,
    line_items: [{
      price: priceId,
      quantity: 1
    }],
    mode: 'subscription',
    success_url: successUrl,
    cancel_url: cancelUrl,
    
    // Apply discounts
    ...(discounts.length > 0 && { discounts }),
    
    // Allow promotion codes to be entered during checkout
    allow_promotion_codes: !couponCode, // Only if not pre-applied
    
    metadata: {
      userId,
      planId,
      ...(couponCode && { coupon_code: couponCode })
    },
    
    subscription_data: {
      metadata: {
        userId,
        planId,
        ...(couponCode && { applied_coupon: couponCode })
      }
    }
  })

  return session
}
```

### Coupon Application API

```typescript
// app/api/coupons/validate/route.ts
export async function POST(request: Request) {
  try {
    const { code, planId, billingInterval } = await request.json()

    if (!code || typeof code !== 'string') {
      return new Response(
      JSON.stringify({ error: 'Coupon code is required' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    const couponManager = new CouponManager()
    const validation = await couponManager.validateCouponCode(code)

    if (!validation.valid) {
      return new Response(
      JSON.stringify({ 
        valid: false, 
        error: validation.error 
      ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    // Calculate discount amount
    const basePrice = getPlanPrice(planId, billingInterval || 'month')
    let discountAmount = 0
    let discountDescription = ''

    if (validation.coupon.percent_off) {
      discountAmount = basePrice * (validation.coupon.percent_off / 100)
      discountDescription = `${validation.coupon.percent_off}% off`
    } else if (validation.coupon.amount_off) {
      discountAmount = validation.coupon.amount_off
      discountDescription = `$${validation.coupon.amount_off / 100} off`
    }

    const finalPrice = Math.max(0, basePrice - discountAmount)

    return new Response(
      JSON.stringify({
      valid: true,
      coupon: {
        code: validation.promotionCode.code,
        description: discountDescription,
        discountAmount: discountAmount / 100,
        finalPrice: finalPrice / 100,
        duration: validation.coupon.duration,
        durationInMonths: validation.coupon.duration_in_months
      }
    })

  } catch (error) {
    console.error('Coupon validation error:', error)
    return new Response(
      JSON.stringify({ error: 'Validation failed' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Promotional Pricing UI

### Coupon Input Component

```typescript
// components/billing/CouponInput.tsx
import { useState } from 'react'
import { CheckCircleIcon, XCircleIcon } from '@heroicons/react/24/outline'

interface CouponInputProps {
  planId: string
  billingInterval: 'month' | 'year'
  onCouponApplied: (coupon: any) => void
  onCouponRemoved: () => void
}

export function CouponInput({ 
  planId, 
  billingInterval, 
  onCouponApplied, 
  onCouponRemoved 
}: CouponInputProps) {
  const [code, setCode] = useState('')
  const [loading, setLoading] = useState(false)
  const [appliedCoupon, setAppliedCoupon] = useState<any>(null)
  const [error, setError] = useState<string | null>(null)

  const validateCoupon = async () => {
    if (!code.trim()) return

    setLoading(true)
    setError(null)

    try {
      const response = await fetch('/api/coupons/validate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          code: code.trim(),
          planId,
          billingInterval
        })
      })

      const data = await response.json()

      if (response.ok && data.valid) {
        setAppliedCoupon(data.coupon)
        onCouponApplied(data.coupon)
        setError(null)
      } else {
        setError(data.error || 'Invalid coupon code')
        setAppliedCoupon(null)
      }

    } catch (err) {
      setError('Failed to validate coupon')
      setAppliedCoupon(null)
    } finally {
      setLoading(false)
    }
  }

  const removeCoupon = () => {
    setCode('')
    setAppliedCoupon(null)
    setError(null)
    onCouponRemoved()
  }

  return (
    <div className="space-y-3">
      {!appliedCoupon ? (
        <div className="flex space-x-2">
          <input
            type="text"
            value={code}
            onChange={(e) => setCode(e.target.value.toUpperCase())}
            placeholder="Enter coupon code"
            className="flex-1 px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500"
            disabled={loading}
          />
          <button
            onClick={validateCoupon}
            disabled={loading || !code.trim()}
            className="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 disabled:opacity-50"
          >
            {loading ? 'Checking...' : 'Apply'}
          </button>
        </div>
      ) : (
        <div className="flex items-center justify-between p-3 bg-green-50 border border-green-200 rounded-md">
          <div className="flex items-center">
            <CheckCircleIcon className="h-5 w-5 text-green-500 mr-2" />
            <div>
              <p className="text-sm font-medium text-green-800">
                Coupon Applied: {appliedCoupon.code}
              </p>
              <p className="text-sm text-green-600">
                {appliedCoupon.description} - Save ${appliedCoupon.discountAmount}
              </p>
            </div>
          </div>
          <button
            onClick={removeCoupon}
            className="text-sm text-green-600 hover:text-green-700 underline"
          >
            Remove
          </button>
        </div>
      )}

      {error && (
        <div className="flex items-center p-3 bg-red-50 border border-red-200 rounded-md">
          <XCircleIcon className="h-5 w-5 text-red-500 mr-2" />
          <p className="text-sm text-red-600">{error}</p>
        </div>
      )}
    </div>
  )
}
```

### Pricing Display with Discounts

```typescript
// components/billing/DiscountedPricing.tsx
interface DiscountedPricingProps {
  planId: string
  billingInterval: 'month' | 'year'
  appliedCoupon?: any
}

export function DiscountedPricing({ 
  planId, 
  billingInterval, 
  appliedCoupon 
}: DiscountedPricingProps) {
  const basePrice = getPlanPrice(planId, billingInterval) / 100
  const intervalDisplay = billingInterval === 'month' ? 'mo' : 'yr'

  if (!appliedCoupon) {
    return (
      <div>
        <span className="text-3xl font-bold">${basePrice}</span>
        <span className="text-gray-600">/{intervalDisplay}</span>
      </div>
    )
  }

  const discountedPrice = appliedCoupon.finalPrice
  const savings = basePrice - discountedPrice

  return (
    <div>
      <div className="flex items-baseline space-x-2">
        <span className="text-3xl font-bold text-green-600">
          ${discountedPrice}
        </span>
        <span className="text-lg text-gray-500 line-through">
          ${basePrice}
        </span>
        <span className="text-gray-600">/{intervalDisplay}</span>
      </div>
      
      <div className="mt-1">
        <span className="inline-flex items-center px-2 py-1 rounded-full text-xs font-medium bg-green-100 text-green-800">
          Save ${savings} with {appliedCoupon.code}
        </span>
      </div>

      {appliedCoupon.duration !== 'forever' && (
        <p className="text-sm text-gray-600 mt-2">
          {appliedCoupon.duration === 'once' 
            ? 'Discount applies to first payment only'
            : `Discount applies for ${appliedCoupon.durationInMonths} months`
          }
        </p>
      )}
    </div>
  )
}
```

## Coupon Campaign Management

### Campaign Creation and Tracking

```typescript
// lib/promotions/campaign-management.ts
export class CouponCampaign {
  async createCampaign(
    name: string,
    description: string,
    coupons: {
      code: string
      type: 'percentage' | 'fixed'
      value: number
      duration: 'once' | 'repeating' | 'forever'
      maxRedemptions?: number
      expiresAt?: Date
    }[]
  ) {
    const supabase = createServerServiceRoleClient()
    
    try {
      // Create campaign record
      const { data: campaign, error: campaignError } = await supabase
        .from('coupon_campaigns')
        .insert({
          name,
          description,
          status: 'active',
          created_at: new Date().toISOString()
        })
        .select()
        .single()

      if (campaignError) throw campaignError

      // Create coupons in Stripe and track in database
      const couponManager = new CouponManager()
      const createdCoupons = []

      for (const couponData of coupons) {
        let stripeResult

        if (couponData.type === 'percentage') {
          stripeResult = await couponManager.createPercentageCoupon(
            couponData.code,
            couponData.value,
            couponData.duration,
            {
              maxRedemptions: couponData.maxRedemptions,
              expiresAt: couponData.expiresAt
            }
          )
        } else {
          stripeResult = await couponManager.createFixedAmountCoupon(
            couponData.code,
            couponData.value * 100, // Convert to cents
            'usd',
            couponData.duration,
            {
              maxRedemptions: couponData.maxRedemptions,
              expiresAt: couponData.expiresAt
            }
          )
        }

        // Store coupon details in database
        const { error: couponError } = await supabase
          .from('coupon_codes')
          .insert({
            campaign_id: campaign.id,
            code: stripeResult.code,
            stripe_coupon_id: stripeResult.couponId,
            stripe_promotion_code_id: stripeResult.promotionCodeId,
            type: couponData.type,
            value: couponData.value,
            duration: couponData.duration,
            max_redemptions: couponData.maxRedemptions,
            expires_at: couponData.expiresAt?.toISOString(),
            created_at: new Date().toISOString()
          })

        if (couponError) {
          console.error('Failed to store coupon in database:', couponError)
        } else {
          createdCoupons.push(stripeResult)
        }
      }

      console.log(`✅ Created campaign "${name}" with ${createdCoupons.length} coupons`)

      return {
        campaign,
        coupons: createdCoupons
      }

    } catch (error) {
      console.error('Campaign creation failed:', error)
      throw error
    }
  }

  async getCampaignStats(campaignId: string) {
    const supabase = createServerServiceRoleClient()

    try {
      // Get campaign details
      const { data: campaign } = await supabase
        .from('coupon_campaigns')
        .select('*')
        .eq('id', campaignId)
        .single()

      // Get coupon usage stats
      const { data: coupons } = await supabase
        .from('coupon_codes')
        .select('code, stripe_coupon_id, max_redemptions')
        .eq('campaign_id', campaignId)

      if (!coupons) {
        return { campaign, stats: null }
      }

      // Get redemption data from Stripe
      const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
        apiVersion: '2025-08-27.basil'
      })

      const couponStats = await Promise.all(
        coupons.map(async (coupon) => {
          const stripeCoupon = await stripe.coupons.retrieve(coupon.stripe_coupon_id)
          
          return {
            code: coupon.code,
            timesRedeemed: stripeCoupon.times_redeemed || 0,
            maxRedemptions: coupon.max_redemptions || null,
            redemptionRate: coupon.max_redemptions ? 
              ((stripeCoupon.times_redeemed || 0) / coupon.max_redemptions) * 100 : null
          }
        })
      )

      const totalRedemptions = couponStats.reduce((sum, stat) => sum + stat.timesRedeemed, 0)
      const totalMaxRedemptions = couponStats.reduce((sum, stat) => sum + (stat.maxRedemptions || 0), 0)

      return {
        campaign,
        stats: {
          totalCoupons: coupons.length,
          totalRedemptions,
          totalMaxRedemptions,
          overallRedemptionRate: totalMaxRedemptions > 0 ? 
            (totalRedemptions / totalMaxRedemptions) * 100 : null,
          couponBreakdown: couponStats
        }
      }

    } catch (error) {
      console.error('Failed to get campaign stats:', error)
      throw error
    }
  }
}
```

## Free Trial Implementation

### Trial Period Management

```typescript
// lib/promotions/free-trials.ts
export class FreeTrialManager {
  async createTrialSubscription(
    userId: string,
    userEmail: string,
    planId: string,
    trialDays: number = 14
  ) {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    try {
      // Get or create customer
      const customer = await getOrCreateStripeCustomer(userId, userEmail)

      // Create subscription with trial
      const priceId = getStripePriceId(planId, 'month')
      if (!priceId) {
        throw new Error('Invalid plan')
      }

      const trialEnd = Math.floor((Date.now() + trialDays * 24 * 60 * 60 * 1000) / 1000)

      const subscription = await stripe.subscriptions.create({
        customer: customer.id,
        items: [{ price: priceId }],
        trial_end: trialEnd,
        payment_behavior: 'default_incomplete',
        payment_settings: {
          save_default_payment_method: 'on_subscription'
        },
        metadata: {
          userId,
          planId,
          trial_days: trialDays.toString(),
          trial_source: 'free_trial_campaign'
        }
      })

      // Update database
      const supabase = createServerServiceRoleClient()
      await supabase
        .from('subscriptions')
        .upsert({
          user_id: userId,
          stripe_subscription_id: subscription.id,
          stripe_customer_id: customer.id,
          stripe_price_id: priceId,
          plan_id: planId,
          status: 'trialing',
          current_period_start: new Date(subscription.current_period_start * 1000).toISOString(),
          current_period_end: new Date(subscription.current_period_end * 1000).toISOString(),
          trial_end: new Date(trialEnd * 1000).toISOString(),
          metadata: {
            trial_days: trialDays,
            trial_source: 'free_trial_campaign'
          },
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString()
        }, {
          onConflict: 'user_id'
        })

      console.log(`✅ Created ${trialDays}-day trial for user ${userId}`)

      return {
        subscriptionId: subscription.id,
        trialEnd: new Date(trialEnd * 1000),
        status: subscription.status
      }

    } catch (error) {
      console.error('Free trial creation failed:', error)
      throw error
    }
  }

  async getTrialStatus(userId: string): Promise<{
    isOnTrial: boolean
    trialEnd?: Date
    daysRemaining?: number
    planId?: string
  }> {
    try {
      const subscription = await getSubscriptionDetails(userId)
      
      if (!subscription || subscription.status !== 'trialing') {
        return { isOnTrial: false }
      }

      const trialEnd = subscription.trial_end ? new Date(subscription.trial_end) : null
      const now = new Date()
      
      if (!trialEnd || trialEnd <= now) {
        return { isOnTrial: false }
      }

      const daysRemaining = Math.ceil((trialEnd.getTime() - now.getTime()) / (24 * 60 * 60 * 1000))

      return {
        isOnTrial: true,
        trialEnd,
        daysRemaining,
        planId: subscription.planId
      }

    } catch (error) {
      console.error('Failed to get trial status:', error)
      return { isOnTrial: false }
    }
  }
}
```

### Trial Status Component

```typescript
// components/billing/TrialStatus.tsx
import { useState, useEffect } from 'react'
import { ClockIcon } from '@heroicons/react/24/outline'

interface TrialStatusProps {
  userId: string
}

export function TrialStatus({ userId }: TrialStatusProps) {
  const [trialStatus, setTrialStatus] = useState<any>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    loadTrialStatus()
  }, [userId])

  const loadTrialStatus = async () => {
    try {
      const response = await fetch(`/api/billing/trial-status?userId=${userId}`)
      if (response.ok) {
        const data = await response.json()
        setTrialStatus(data)
      }
    } catch (error) {
      console.error('Failed to load trial status:', error)
    } finally {
      setLoading(false)
    }
  }

  if (loading) {
    return <div className="animate-pulse bg-gray-200 h-16 rounded-lg"></div>
  }

  if (!trialStatus?.isOnTrial) {
    return null
  }

  const isExpiringSoon = trialStatus.daysRemaining <= 3

  return (
    <div className={`p-4 rounded-lg border ${
      isExpiringSoon 
        ? 'bg-orange-50 border-orange-200' 
        : 'bg-blue-50 border-blue-200'
    }`}>
      <div className="flex items-center">
        <ClockIcon className={`h-5 w-5 mr-3 ${
          isExpiringSoon ? 'text-orange-500' : 'text-blue-500'
        }`} />
        
        <div className="flex-1">
          <h4 className={`font-medium ${
            isExpiringSoon ? 'text-orange-800' : 'text-blue-800'
          }`}>
            Free Trial Active
          </h4>
          
          <p className={`text-sm ${
            isExpiringSoon ? 'text-orange-600' : 'text-blue-600'
          }`}>
            {trialStatus.daysRemaining > 0 
              ? `${trialStatus.daysRemaining} days remaining`
              : 'Trial expires today'
            } on your {trialStatus.planId} plan
          </p>
        </div>

        {isExpiringSoon && (
          <button
            onClick={() => window.location.href = '/billing'}
            className="bg-orange-600 text-white px-4 py-2 rounded-md text-sm hover:bg-orange-700"
          >
            Add Payment Method
          </button>
        )}
      </div>
    </div>
  )
}
```

## Discount Analytics and Reporting

### Coupon Performance Tracking

```typescript
// lib/analytics/coupon-analytics.ts
export class CouponAnalytics {
  async getCouponPerformance(timeframe: '7d' | '30d' | '90d' = '30d') {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    const days = timeframe === '7d' ? 7 : timeframe === '30d' ? 30 : 90
    const since = Math.floor((Date.now() - days * 24 * 60 * 60 * 1000) / 1000)

    try {
      // Get invoices with discounts
      const invoices = await stripe.invoices.list({
        created: { gte: since },
        status: 'paid',
        expand: ['data.discount', 'data.subscription'],
        limit: 100
      })

      const discountAnalytics = invoices.data
        .filter(invoice => invoice.discount)
        .reduce((acc, invoice) => {
          const couponId = invoice.discount?.coupon?.id
          if (!couponId) return acc

          if (!acc[couponId]) {
            acc[couponId] = {
              couponId,
              code: invoice.discount?.promotion_code || 'Unknown',
              redemptions: 0,
              totalDiscount: 0,
              averageOrderValue: 0,
              customers: new Set()
            }
          }

          acc[couponId].redemptions += 1
          acc[couponId].totalDiscount += (invoice.discount?.amount || 0) / 100
          acc[couponId].customers.add(invoice.customer)

          return acc
        }, {} as Record<string, any>)

      // Calculate average order values
      Object.values(discountAnalytics).forEach((data: any) => {
        data.uniqueCustomers = data.customers.size
        data.averageDiscount = data.totalDiscount / data.redemptions
        delete data.customers // Remove Set for JSON serialization
      })

      return {
        timeframe,
        summary: {
          totalCouponsUsed: Object.keys(discountAnalytics).length,
          totalRedemptions: Object.values(discountAnalytics).reduce((sum: number, data: any) => 
            sum + data.redemptions, 0),
          totalDiscountAmount: Object.values(discountAnalytics).reduce((sum: number, data: any) => 
            sum + data.totalDiscount, 0),
          uniqueCustomers: new Set(
            Object.values(discountAnalytics).flatMap((data: any) => Array.from(data.customers))
          ).size
        },
        coupons: Object.values(discountAnalytics)
      }

    } catch (error) {
      console.error('Coupon analytics failed:', error)
      throw error
    }
  }

  async getTopPerformingCoupons(limit: number = 10) {
    const performance = await this.getCouponPerformance('30d')
    
    return performance.coupons
      .sort((a: any, b: any) => b.redemptions - a.redemptions)
      .slice(0, limit)
  }
}
```

## Testing Coupon Functionality

### Coupon Integration Tests

```typescript
// __tests__/integration/coupons.test.ts
describe('Coupon Integration', () => {
  let testCoupon: any
  let couponManager: CouponManager

  beforeAll(async () => {
    couponManager = new CouponManager()
    
    // Create test coupon
    testCoupon = await couponManager.createPercentageCoupon(
      'TEST20',
      20,
      'once',
      { maxRedemptions: 10 }
    )
  })

  afterAll(async () => {
    // Clean up test coupon
    if (testCoupon) {
      const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
        apiVersion: '2025-08-27.basil'
      })
      
      await stripe.promotionCodes.update(testCoupon.promotionCodeId, { active: false })
    }
  })

  it('should validate coupon codes correctly', async () => {
    const validation = await couponManager.validateCouponCode('TEST20')
    
    expect(validation.valid).toBe(true)
    expect(validation.coupon?.percent_off).toBe(20)
    expect(validation.promotionCode?.code).toBe('TEST20')
  })

  it('should reject invalid coupon codes', async () => {
    const validation = await couponManager.validateCouponCode('INVALID')
    
    expect(validation.valid).toBe(false)
    expect(validation.error).toBe('Coupon code not found')
  })

  it('should create checkout session with coupon', async () => {
    const session = await createCheckoutSessionWithCoupon(
      'test_user_123',
      'test@example.com',
      'starter',
      'https://example.com/success',
      'https://example.com/cancel',
      'month',
      'TEST20'
    )

    expect(session.url).toContain('checkout.stripe.com')
    // Verify discount is applied in session
  })
})
```

### E2E Coupon Tests

```typescript
// cypress/e2e/billing/coupons.cy.ts
describe('Coupon Flow', () => {
  beforeEach(() => {
    cy.task('createTestCoupon', { 
      code: 'CYPRESS20', 
      percentOff: 20 
    })
  })

  afterEach(() => {
    cy.task('deactivateTestCoupon', { code: 'CYPRESS20' })
  })

  it('should apply coupon during checkout', () => {
    cy.visit('/pricing')
    
    // Select a plan
    cy.get('[data-testid="starter-select-button"]').click()
    
    // Should show coupon input
    cy.get('[data-testid="coupon-input"]').should('be.visible')
    
    // Enter coupon code
    cy.get('[data-testid="coupon-code-input"]').type('CYPRESS20')
    cy.get('[data-testid="apply-coupon-button"]').click()
    
    // Should show discount applied
    cy.get('[data-testid="applied-coupon"]').should('be.visible')
    cy.get('[data-testid="applied-coupon"]').should('contain', '20% off')
    
    // Should show discounted price
    cy.get('[data-testid="discounted-price"]').should('be.visible')
    cy.get('[data-testid="original-price"]').should('have.class', 'line-through')
    
    // Proceed to checkout
    cy.get('[data-testid="checkout-button"]').click()
    
    // Should redirect to Stripe checkout with discount
    cy.url().should('include', 'checkout.stripe.com')
  })

  it('should handle invalid coupon codes', () => {
    cy.visit('/pricing')
    
    cy.get('[data-testid="starter-select-button"]').click()
    cy.get('[data-testid="coupon-code-input"]').type('INVALID')
    cy.get('[data-testid="apply-coupon-button"]').click()
    
    // Should show error message
    cy.get('[data-testid="coupon-error"]').should('be.visible')
    cy.get('[data-testid="coupon-error"]').should('contain', 'Invalid coupon code')
  })
})
```

## Alternative: Simple Discount Implementation

If you want basic discounts without full coupon management:

### Simple Percentage Discount

```typescript
// lib/promotions/simple-discounts.ts (Alternative approach)
export class SimpleDiscounts {
  private discounts: Record<string, {
    percentage: number
    validUntil: Date
    applicablePlans: string[]
  }> = {
    'LAUNCH50': {
      percentage: 50,
      validUntil: new Date('2024-12-31'),
      applicablePlans: ['starter', 'pro']
    },
    'STUDENT20': {
      percentage: 20,
      validUntil: new Date('2025-12-31'),
      applicablePlans: ['starter']
    }
  }

  validateDiscount(code: string, planId: string): {
    valid: boolean
    discount?: number
    error?: string
  } {
    const discount = this.discounts[code.toUpperCase()]
    
    if (!discount) {
      return { valid: false, error: 'Discount code not found' }
    }

    if (new Date() > discount.validUntil) {
      return { valid: false, error: 'Discount code has expired' }
    }

    if (!discount.applicablePlans.includes(planId)) {
      return { valid: false, error: 'Discount not valid for this plan' }
    }

    return { valid: true, discount: discount.percentage }
  }

  applyDiscount(price: number, discountPercentage: number): {
    originalPrice: number
    discountAmount: number
    finalPrice: number
  } {
    const discountAmount = price * (discountPercentage / 100)
    const finalPrice = price - discountAmount

    return {
      originalPrice: price,
      discountAmount,
      finalPrice: Math.max(0, finalPrice)
    }
  }
}
```

## Next Steps

In the next module, we'll cover handling failed payments and implementing dunning management strategies.

## Key Takeaways

- **Use Stripe's coupon system** for robust discount management
- **Validate coupon codes** before applying to prevent fraud
- **Track coupon performance** to measure campaign effectiveness
- **Implement free trials** to reduce signup friction
- **Display discounted pricing clearly** to show value to customers
- **Support both percentage and fixed amount discounts**
- **Set appropriate expiration dates** and redemption limits
- **Test coupon flows** thoroughly including error scenarios
- **Monitor coupon usage** to prevent abuse
- **Consider simple discount systems** for basic promotional needs
