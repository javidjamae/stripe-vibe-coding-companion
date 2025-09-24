# Checkout Sessions and Payment Flow

## Overview

This module covers creating and handling Stripe checkout sessions, the primary way users subscribe to your plans. We'll explore the patterns used in your codebase for seamless payment collection and subscription creation.

## Checkout Session Fundamentals

Stripe Checkout is a pre-built payment page that handles:
- Payment method collection
- Tax calculation
- Subscription creation
- Customer creation/management
- Redirect handling

Your codebase uses checkout sessions for all new subscriptions and plan changes.

## Creating Checkout Sessions

### Core Implementation (Framework-Agnostic)

Our recommended approach uses the framework-agnostic billing functions from our core system:

```typescript
// Based on packages/core-server patterns
import { createCheckoutSession, BillingDependencies } from './lib/billing'

export async function createCheckoutSessionForPlan(
  input: {
    userId: string
    userEmail: string
    planId: string
    successUrl: string
    cancelUrl: string
    billingInterval: 'month' | 'year'
  },
  dependencies: BillingDependencies
): Promise<{ url: string }> {
  
  // Get the plan details to find the Stripe Price ID
  const plans = await getAvailablePlans(input.billingInterval, dependencies)
  const plan = plans.find(p => p.id === input.planId)
  
  if (!plan) {
    throw new Error('Plan not found')
  }
  
  // Import Stripe dynamically to avoid issues in test environment
  const Stripe = (await import('stripe')).default
  const stripe = new Stripe(dependencies.stripeSecretKey, {
    apiVersion: '2023-10-16'
  })
  
  // Hybrid approach: Check if user already has a Stripe customer ID
  const existingSubscription = await getSubscriptionDetails(input.userId, dependencies)
  let stripeCustomerId
  
  if (existingSubscription?.stripeCustomerId) {
    // User already has a Stripe customer - use existing ID (plan change scenario)
    stripeCustomerId = existingSubscription.stripeCustomerId
  } else {
    // New customer - create or get from Stripe (first subscription scenario)
    let customer = await stripe.customers.list({ email: input.userEmail, limit: 1 })
    
    if (customer.data.length > 0) {
      // Customer already exists in Stripe with this email
      stripeCustomerId = customer.data[0].id
    } else {
      // Create new customer in Stripe
      const newCustomer = await stripe.customers.create({
        email: input.userEmail,
        metadata: {
          userId: input.userId
        }
      })
      stripeCustomerId = newCustomer.id
    }
  }
  
  // Create the checkout session with the customer ID (email will be locked)
  const session = await stripe.checkout.sessions.create({
    customer: stripeCustomerId, // Use customer ID instead of customer_email
    line_items: [{
      price: plan.stripePriceId,
      quantity: 1
    }],
    mode: 'subscription',
    success_url: successUrl,
    cancel_url: cancelUrl,
    metadata: {
      userId: userId,
      planId: planId,
      billingInterval: billingInterval
    },
    allow_promotion_codes: true,
    billing_address_collection: 'auto',
    tax_id_collection: {
      enabled: true
    }
  })

  return { url: session.url! }
}
```

### API Endpoint Implementation

```typescript
// app/api/billing/create-checkout-session/route.ts
// Framework-agnostic imports
import { createServerUserClient } from '@/lib/supabase-clients'
import { createCheckoutSessionForPlan } from '@/lib/billing'

export async function POST(request: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    const { planId, billingInterval = 'month' } = await request.json()
    
    if (!planId) {
      return new Response(
      JSON.stringify({ error: 'Missing planId' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    // Validate plan exists and user can subscribe
    const plans = await getAvailablePlans(billingInterval)
    const plan = plans.find(p => p.id === planId)
    
    if (!plan) {
      return new Response(
      JSON.stringify({ error: 'Invalid plan' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    // Check if user already has an active subscription
    const existingSubscription = await getSubscriptionDetails(user.id)
    if (existingSubscription && existingSubscription.status === 'active') {
      return new Response(
      JSON.stringify({ 
        error: 'User already has an active subscription. Use upgrade/downgrade endpoints.' 
      ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    // Create checkout session
    const { url } = await createCheckoutSessionForPlan(
      user.id,
      user.email!,
      planId,
      `${process.env.APP_URL}/billing?success=true`,
      `${process.env.APP_URL}/billing?canceled=true`,
      billingInterval
    )

    return new Response(
      JSON.stringify({ url })
  } catch (error) {
    console.error('Checkout session creation failed:', error)
    return new Response(
      JSON.stringify(
      { error: 'Failed to create checkout session' },
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

## Customer Management Strategy

Your codebase implements a hybrid customer management approach:

### 1. Check Database First

```typescript
const existingSubscription = await getSubscriptionDetails(userId)
if (existingSubscription?.stripeCustomerId) {
  // Use existing customer ID from our database
  stripeCustomerId = existingSubscription.stripeCustomerId
}
```

### 2. Fallback to Stripe Search

```typescript
else {
  // Search for existing customer by email
  let customer = await stripe.customers.list({ email: userEmail, limit: 1 })
  
  if (customer.data.length > 0) {
    stripeCustomerId = customer.data[0].id
  }
}
```

### 3. Create New Customer

```typescript
else {
  // Create new customer with metadata
  const newCustomer = await stripe.customers.create({
    email: userEmail,
    metadata: {
      userId: userId  // Link back to your system
    }
  })
  stripeCustomerId = newCustomer.id
}
```

## Frontend Integration

### React Hook for Checkout

```typescript
// hooks/useCheckout.ts
import { useState } from 'react'

export function useCheckout() {
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const createCheckoutSession = async (planId: string, billingInterval: 'month' | 'year' = 'month') => {
    setLoading(true)
    setError(null)

    try {
      const response = await fetch('/api/billing/create-checkout-session', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ planId, billingInterval }),
      })

      const data = await response.json()

      if (!response.ok) {
        throw new Error(data.error || 'Failed to create checkout session')
      }

      // Redirect to Stripe Checkout
      window.location.href = data.url
    } catch (err) {
      setError(err instanceof Error ? err.message : 'An error occurred')
    } finally {
      setLoading(false)
    }
  }

  return {
    createCheckoutSession,
    loading,
    error
  }
}
```

### Plan Card Component

```typescript
// components/billing/PlanCard.tsx
import { useCheckout } from '@/hooks/useCheckout'

interface PlanCardProps {
  plan: {
    id: string
    name: string
    monthlyPriceCents: number
    annualPriceCents: number
    features: string[]
  }
  billingInterval: 'month' | 'year'
  currentPlan?: string
}

export function PlanCard({ plan, billingInterval, currentPlan }: PlanCardProps) {
  const { createCheckoutSession, loading, error } = useCheckout()
  
  const price = billingInterval === 'month' ? plan.monthlyPriceCents : plan.annualPriceCents
  const priceDisplay = `$${(price / 100).toFixed(0)}/${billingInterval === 'month' ? 'mo' : 'yr'}`
  
  const isCurrentPlan = currentPlan === plan.id
  
  const handleSelectPlan = async () => {
    if (isCurrentPlan) return
    
    await createCheckoutSession(plan.id, billingInterval)
  }

  return (
    <div className="border rounded-lg p-6">
      <h3 className="text-xl font-semibold">{plan.name}</h3>
      <div className="text-3xl font-bold mt-2">{priceDisplay}</div>
      
      <ul className="mt-4 space-y-2">
        {plan.features.map((feature, index) => (
          <li key={index} className="flex items-center">
            <CheckIcon className="w-4 h-4 text-green-500 mr-2" />
            {feature}
          </li>
        ))}
      </ul>
      
      {error && (
        <div className="text-red-600 text-sm mt-2">{error}</div>
      )}
      
      <button
        onClick={handleSelectPlan}
        disabled={loading || isCurrentPlan}
        className={`w-full mt-6 py-2 px-4 rounded-md font-medium ${
          isCurrentPlan
            ? 'bg-green-100 text-green-800 cursor-not-allowed'
            : 'bg-blue-600 text-white hover:bg-blue-700'
        }`}
      >
        {loading ? 'Creating...' : isCurrentPlan ? 'Current Plan' : 'Select Plan'}
      </button>
    </div>
  )
}
```

## Success and Cancel Handling

### Success Page

```typescript
// app/billing/page.tsx
'use client'

import { useEffect, useState } from 'react'
import { useSearchParams } from 'next/navigation'

export default function BillingPage() {
  const searchParams = useSearchParams()
  const [showSuccess, setShowSuccess] = useState(false)
  const [showCanceled, setShowCanceled] = useState(false)

  useEffect(() => {
    const success = searchParams.get('success')
    const canceled = searchParams.get('canceled')
    
    if (success === 'true') {
      setShowSuccess(true)
      // Clear URL parameters
      window.history.replaceState({}, '', '/billing')
      
      // Auto-hide after 5 seconds
      setTimeout(() => setShowSuccess(false), 5000)
    }
    
    if (canceled === 'true') {
      setShowCanceled(true)
      // Clear URL parameters
      window.history.replaceState({}, '', '/billing')
      
      // Auto-hide after 3 seconds
      setTimeout(() => setShowCanceled(false), 3000)
    }
  }, [searchParams])

  return (
    <div className="max-w-4xl mx-auto p-6">
      {showSuccess && (
        <div className="bg-green-100 border border-green-400 text-green-700 px-4 py-3 rounded mb-6">
          <strong>Success!</strong> Your subscription has been activated.
        </div>
      )}
      
      {showCanceled && (
        <div className="bg-yellow-100 border border-yellow-400 text-yellow-700 px-4 py-3 rounded mb-6">
          <strong>Canceled:</strong> Your checkout was canceled. No charges were made.
        </div>
      )}
      
      {/* Rest of billing page content */}
    </div>
  )
}
```

## Checkout Session Configuration Options

Your codebase can be extended with additional checkout options:

### Tax Collection

```typescript
const session = await stripe.checkout.sessions.create({
  // ... other options
  tax_id_collection: {
    enabled: true
  },
  automatic_tax: {
    enabled: true
  }
})
```

### Promotion Codes

```typescript
const session = await stripe.checkout.sessions.create({
  // ... other options
  allow_promotion_codes: true,
  discounts: [{
    coupon: 'LAUNCH50'  // Pre-apply a specific coupon
  }]
})
```

### Custom Fields

```typescript
const session = await stripe.checkout.sessions.create({
  // ... other options
  custom_fields: [{
    key: 'company_name',
    label: {
      type: 'custom',
      custom: 'Company Name'
    },
    type: 'text',
    optional: true
  }]
})
```

### Phone Number Collection

```typescript
const session = await stripe.checkout.sessions.create({
  // ... other options
  phone_number_collection: {
    enabled: true
  }
})
```

## Error Handling Patterns

### Common Checkout Errors

```typescript
export async function createCheckoutSessionForPlan(...args) {
  try {
    const session = await stripe.checkout.sessions.create({...})
    return { url: session.url! }
  } catch (error) {
    if (error instanceof Stripe.errors.StripeError) {
      switch (error.code) {
        case 'resource_missing':
          throw new Error('Invalid price ID or product configuration')
        case 'parameter_invalid_empty':
          throw new Error('Missing required checkout parameters')
        case 'email_invalid':
          throw new Error('Invalid customer email address')
        default:
          console.error('Stripe checkout error:', error)
          throw new Error('Failed to create checkout session')
      }
    }
    throw error
  }
}
```

### Frontend Error Display

```typescript
// components/ErrorBoundary.tsx
export function CheckoutErrorBoundary({ children }: { children: React.ReactNode }) {
  const [error, setError] = useState<string | null>(null)

  const handleError = (error: Error) => {
    console.error('Checkout error:', error)
    
    // User-friendly error messages
    const userMessage = error.message.includes('price ID') 
      ? 'This plan is currently unavailable. Please try again later.'
      : 'There was an issue processing your request. Please try again.'
    
    setError(userMessage)
  }

  if (error) {
    return (
      <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
        <p>{error}</p>
        <button 
          onClick={() => setError(null)}
          className="mt-2 text-sm underline"
        >
          Try again
        </button>
      </div>
    )
  }

  return <>{children}</>
}
```

## Testing Checkout Flow

### Test Cards

Use Stripe's test card numbers:

```typescript
// Test card numbers for different scenarios
const TEST_CARDS = {
  SUCCESS: '4242424242424242',
  DECLINED: '4000000000000002',
  INSUFFICIENT_FUNDS: '4000000000009995',
  EXPIRED_CARD: '4000000000000069',
  INCORRECT_CVC: '4000000000000127'
}
```

### Cypress E2E Testing

```typescript
// cypress/e2e/checkout-flow.cy.ts
describe('Checkout Flow', () => {
  beforeEach(() => {
    // Login as test user
    cy.login('test@example.com')
  })

  it('should create checkout session for starter plan', () => {
    cy.visit('/billing')
    
    // Click on starter plan
    cy.get('[data-testid="starter-plan-button"]').click()
    
    // Should redirect to Stripe checkout
    cy.url().should('include', 'checkout.stripe.com')
    
    // Fill in test card details
    cy.get('[data-testid="cardNumber"]').type('4242424242424242')
    cy.get('[data-testid="cardExpiry"]').type('12/34')
    cy.get('[data-testid="cardCvc"]').type('123')
    cy.get('[data-testid="billingName"]').type('Test User')
    
    // Submit payment
    cy.get('[data-testid="submit"]').click()
    
    // Should redirect back to success page
    cy.url().should('include', '/billing?success=true')
    cy.get('[data-testid="success-message"]').should('be.visible')
  })
})
```

### Unit Testing

```typescript
// __tests__/lib/billing.test.ts
import { createCheckoutSessionForPlan } from '@/lib/billing'
import Stripe from 'stripe'

// Mock Stripe
jest.mock('stripe')

describe('createCheckoutSessionForPlan', () => {
  const mockStripe = {
    customers: {
      list: jest.fn(),
      create: jest.fn()
    },
    checkout: {
      sessions: {
        create: jest.fn()
      }
    }
  } as any

  beforeEach(() => {
    (Stripe as jest.MockedClass<typeof Stripe>).mockImplementation(() => mockStripe)
  })

  it('should create checkout session for new customer', async () => {
    // Mock empty customer list (new customer)
    mockStripe.customers.list.mockResolvedValue({ data: [] })
    mockStripe.customers.create.mockResolvedValue({ id: 'cus_new123' })
    mockStripe.checkout.sessions.create.mockResolvedValue({ 
      url: 'https://checkout.stripe.com/pay/test123' 
    })

    const result = await createCheckoutSessionForPlan(
      'user123',
      'test@example.com',
      'starter',
      'http://localhost:3000/success',
      'http://localhost:3000/cancel'
    )

    expect(result.url).toBe('https://checkout.stripe.com/pay/test123')
    expect(mockStripe.customers.create).toHaveBeenCalledWith({
      email: 'test@example.com',
      metadata: { userId: 'user123' }
    })
  })
})
```

## Checkout Session Metadata

Store important context in checkout session metadata:

```typescript
const session = await stripe.checkout.sessions.create({
  // ... other options
  metadata: {
    userId: userId,
    planId: planId,
    billingInterval: billingInterval,
    source: 'billing_page',  // Track where checkout originated
    campaign: 'launch_2024', // Track marketing campaigns
    previous_plan: currentPlanId || 'none' // Track plan changes
  }
})
```

This metadata is available in webhooks for processing and analytics.

## Next Steps

In the next module, we'll cover webhook fundamentals and how to handle the `checkout.session.completed` event to activate subscriptions.

## Key Takeaways

- Use hybrid customer management (database first, Stripe fallback)
- Store important context in checkout session metadata
- Implement proper error handling for common Stripe errors
- Use success/cancel URLs for user feedback
- Test checkout flows with Stripe test cards
- Handle existing customers gracefully
- Configure checkout sessions with tax collection and promotions
- Implement comprehensive frontend error boundaries
