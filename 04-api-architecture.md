# API Architecture for Stripe Integration

## Overview

This module covers the API architecture and authentication patterns for Stripe integration, based on the framework-agnostic patterns from our core billing system. We'll explore how to build secure, maintainable API endpoints that handle billing operations, webhooks, and user management.

## API Route Structure

Based on your codebase analysis, here's the recommended API structure:

### Billing Operations

```
/billing/
├── create-checkout-session     # Create Stripe checkout sessions
├── create-portal-session       # Create customer portal sessions
├── upgrade                     # Handle plan upgrades
├── downgrade                   # Handle plan downgrades
├── downgrade-to-free           # Specific free plan downgrade
├── cancel-plan-change          # Cancel scheduled changes
└── proration-preview           # Preview upgrade costs
```

### Webhook Handlers

```
/webhooks/
└── stripe                      # Stripe webhook endpoint
```

### Admin Operations

```
/admin/
└── reconcile-user-plan         # Admin reconciliation tools
```

## Authentication Patterns

Your codebase uses two distinct authentication contexts:

### 1. User Context (Most API Routes)

Our recommended approach uses framework-agnostic functions with dependency injection:

```typescript
// Based on our core billing system patterns
import { createCheckoutSession, BillingDependencies } from './lib/billing'

export async function handleCreateCheckout(req: Request) {
  // Extract user context (implementation varies by framework)
  const user = await getUserFromRequest(req)
  if (!user) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }), 
      { status: 401, headers: { 'Content-Type': 'application/json' } }
    )
  }
  
  const { planId, successUrl, cancelUrl, billingInterval } = await req.json()
  
  // Use framework-agnostic billing functions
  const dependencies: BillingDependencies = {
    supabase: createSupabaseClient(),
    stripeSecretKey: process.env.STRIPE_SECRET_KEY!,
    getPlanConfig: (planId) => getPlanConfig(planId),
    getAllPlans: () => getAllPlans()
  }
  
  const session = await createCheckoutSession({
    userId: user.id,
    userEmail: user.email,
    planId,
    successUrl,
    cancelUrl,
    billingInterval
  }, dependencies)
  
  return new Response(
    JSON.stringify(session),
    { headers: { 'Content-Type': 'application/json' } }
  )
}
```

**When to use**: User-initiated API calls, plan changes, billing operations

### 2. Service Role Context (Webhooks & Admin)

```typescript
import { createServerServiceRoleClient } from './lib/supabase-clients'

export async function handleWebhookOperation(subscriptionId: string) {
  const supabase = createServerServiceRoleClient()
  
  // Service role bypasses RLS for system operations
  const { data, error } = await supabase
    .from('subscriptions')
    .update({ status: 'active' })
    .eq('stripe_subscription_id', subscriptionId)
    
  if (error) {
    throw new Error(`Database update failed: ${error.message}`)
  }
  
  return data
}
```

**When to use**: Webhook processing, admin operations, system tasks

## Checkout Session Creation

### API Implementation (Framework-Agnostic)

```typescript
// billing/create-checkout-session.ts
import { createCheckoutSession, BillingDependencies } from './lib/billing'

export async function handleCreateCheckoutSession(request: Request): Promise<Response> {
  try {
    // Extract user context (implementation varies by framework)
    const user = await getUserFromRequest(request)
    if (!user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const { planId, billingInterval = 'month' } = await request.json()
    
    if (!planId) {
      return new Response(
        JSON.stringify({ error: 'Missing planId' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Use framework-agnostic billing functions
    const dependencies: BillingDependencies = {
      supabase: createSupabaseClient(),
      stripeSecretKey: process.env.STRIPE_SECRET_KEY!,
      getPlanConfig: (planId) => getPlanConfig(planId),
      getAllPlans: () => getAllPlans()
    }

    // Create checkout session using core billing function
    const session = await createCheckoutSession({
      userId: user.id,
      userEmail: user.email!,
      planId,
      successUrl: `${process.env.APP_URL}/billing?success=true`,
      cancelUrl: `${process.env.APP_URL}/billing?canceled=true`,
      billingInterval
    }, dependencies)

    return new Response(
      JSON.stringify(session),
      { headers: { 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    console.error('Checkout session creation failed:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to create checkout session' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

### Business Logic Implementation

```typescript
// lib/billing.ts
export async function createCheckoutSessionForPlan(
  userId: string,
  userEmail: string,
  planId: string,
  successUrl: string,
  cancelUrl: string,
  billingInterval: 'month' | 'year' = 'month'
) {
  // Get plan configuration
  const plans = await getAvailablePlans(billingInterval)
  const plan = plans.find(p => p.id === planId)
  
  if (!plan) {
    throw new Error('Plan not found')
  }

  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  // Handle existing customer logic
  const existingSubscription = await getSubscriptionDetails(userId)
  let stripeCustomerId

  if (existingSubscription?.stripeCustomerId) {
    stripeCustomerId = existingSubscription.stripeCustomerId
  } else {
    // Create or find customer
    let customer = await stripe.customers.list({ email: userEmail, limit: 1 })
    
    if (customer.data.length > 0) {
      stripeCustomerId = customer.data[0].id
    } else {
      const newCustomer = await stripe.customers.create({
        email: userEmail,
        metadata: { userId: userId }
      })
      stripeCustomerId = newCustomer.id
    }
  }

  // Create checkout session
  const session = await stripe.checkout.sessions.create({
    customer: stripeCustomerId,
    payment_method_types: ['card'],
    line_items: [{
      price: plan.stripePriceId,
      quantity: 1,
    }],
    mode: 'subscription',
    success_url: successUrl,
    cancel_url: cancelUrl,
    metadata: {
      userId: userId,
      planId: planId,
      billingInterval: billingInterval
    }
  })

  return { url: session.url! }
}
```

## Plan Upgrade API

Your codebase implements sophisticated upgrade logic:

```typescript
// billing/upgrade.ts - Framework-agnostic upgrade handler
import { upgradeSubscription, BillingDependencies } from './lib/billing'

export async function handleUpgrade(request: Request): Promise<Response> {
  try {
    // Extract user context (implementation varies by framework)
    const user = await getUserFromRequest(request)
    if (!user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const { newPlanId, newPriceId, billingInterval } = await request.json()
    
    // Validate inputs
    if (!newPlanId) {
      return new Response(
        JSON.stringify({ error: 'Missing newPlanId' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Use framework-agnostic billing functions
    const dependencies: BillingDependencies = {
      supabase: createSupabaseClient(),
      stripeSecretKey: process.env.STRIPE_SECRET_KEY!,
      getPlanConfig: (planId) => getPlanConfig(planId),
      getAllPlans: () => getAllPlans()
    }

    const result = await upgradeSubscription({
      userId: user.id,
      newPlanId,
      newPriceId: newPriceId || getStripePriceId(newPlanId, billingInterval || 'month'),
      billingInterval: billingInterval || 'month'
    }, dependencies)

    if (!result.success) {
      return new Response(
        JSON.stringify({ error: result.error }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: `Successfully upgraded to ${newPlanId}`
      }),
      { headers: { 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Upgrade failed:', error)
    return new Response(
      JSON.stringify({ error: 'Upgrade failed' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

## Proration Preview API

```typescript
// app/api/billing/proration-preview/route.ts
export async function POST(request: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    const { newPriceId } = await request.json()
    if (!newPriceId) {
      return new Response(
      JSON.stringify({ error: 'Missing newPriceId' ),
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

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil',
    })

    // Get current subscription from Stripe
    const current = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
    const currentItem = current.items?.data?.[0]
    
    if (!currentItem) {
      return new Response(
      JSON.stringify({ error: 'No subscription item found' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    // Preview upcoming invoice with proration
    const preview = await stripe.invoices.retrieveUpcoming({
      customer: (current.customer as string),
      subscription: current.id,
      subscription_items: [
        { id: currentItem.id, price: newPriceId },
      ],
      subscription_proration_behavior: 'create_prorations',
    })

    const amountDue = (preview.amount_due ?? 0) / 100
    const currency = (preview.currency || 'usd').toUpperCase()

    return new Response(
      JSON.stringify({
      ok: true,
      amountDue,
      currency,
    })
  } catch (error) {
    console.error('Proration preview error:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to compute proration preview' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Downgrade API with Scheduling

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

    // Check for test mode
    const isTestMode = req.headers.get('x-test-mode') === 'cypress'
    
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

## Customer Portal Integration

```typescript
// app/api/billing/create-portal-session/route.ts
export async function POST(request: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    // Get user's Stripe customer ID
    const { data: subscription } = await supabase
      .from('subscriptions')
      .select('stripe_customer_id')
      .eq('user_id', user.id)
      .single()

    if (!subscription?.stripe_customer_id) {
      return new Response(
      JSON.stringify({ error: 'No customer found' ),
      { status: 404 })
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    // Create portal session
    const portalSession = await stripe.billingPortal.sessions.create({
      customer: subscription.stripe_customer_id,
      return_url: `${process.env.APP_URL}/billing`,
    })

    return new Response(
      JSON.stringify({ url: portalSession.url })
  } catch (error) {
    console.error('Portal session creation failed:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to create portal session' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Webhook Handler Architecture

### Main Webhook Route

```typescript
// app/api/webhooks/stripe/route.ts
// Framework-agnostic imports
import Stripe from 'stripe'
import { createServerServiceRoleClient } from '@/lib/supabase-clients'
import { 
  handleInvoicePaymentPaid,
  handleSubscriptionScheduleCreated,
  handleSubscriptionScheduleUpdated,
  handleSubscriptionScheduleReleased
} from './handlers'

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
  apiVersion: '2025-08-27.basil'
})

const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET!

export async function POST(request: Request) {
  console.log('🚀 Webhook handler started')
  
  try {
    const body = await request.text()
    const signature = request.headers.get('stripe-signature')

    if (!signature) {
      console.log('❌ Missing stripe-signature header')
      return new Response(
      JSON.stringify(
        { error: 'Missing stripe-signature header' },
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    let event: Stripe.Event
    
    try {
      event = stripe.webhooks.constructEvent(body, signature, webhookSecret)
      console.log('✅ Signature verification successful')
    } catch (err) {
      console.error('❌ Webhook signature verification failed:', err)
      return new Response(
      JSON.stringify(
        { error: 'Invalid signature' },
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    console.log('👋🏼 Received Stripe webhook event:', event.type)

    // Route to specific handlers
    switch (event.type) {
      case 'invoice.payment_succeeded':
        await handleInvoicePaymentPaid(event.data.object)
        break
      
      case 'subscription_schedule.created':
        await handleSubscriptionScheduleCreated(event.data.object)
        break
      
      case 'subscription_schedule.updated':
        await handleSubscriptionScheduleUpdated(event.data.object)
        break
      
      case 'subscription_schedule.released':
        await handleSubscriptionScheduleReleased(event.data.object)
        break
      
      default:
        console.log(`Unhandled event type: ${event.type}`)
    }

    return new Response(
      JSON.stringify({ received: true })
  } catch (error) {
    console.error('❌ Webhook processing failed:', error)
    return new Response(
      JSON.stringify({ error: 'Webhook processing failed' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Error Handling Patterns

### Standardized Error Responses

```typescript
// lib/api-errors.ts
export class APIError extends Error {
  constructor(
    public message: string,
    public statusCode: number,
    public code?: string
  ) {
    super(message)
    this.name = 'APIError'
  }
}

export function handleAPIError(error: unknown): Response {
  if (error instanceof APIError) {
    return new Response(
      JSON.stringify(
      { error: error.message, code: error.code },
      { status: error.statusCode }
    )
  }
  
  if (error instanceof Stripe.errors.StripeError) {
    return new Response(
      JSON.stringify(
      { error: error.message, type: error.type },
      { status: error.statusCode || 500 }
    )
  }
  
  console.error('Unexpected error:', error)
  return new Response(
      JSON.stringify(
    { error: 'Internal server error' },
    { status: 500, headers: { 'Content-Type': 'application/json' } }
  )
}
```

### Usage in API Routes

```typescript
export async function POST(request: Request) {
  try {
    // API logic here
    return new Response(
      JSON.stringify({ success: true })
  } catch (error) {
    return handleAPIError(error)
  }
}
```

## Request Validation

### Input Validation Middleware

```typescript
// lib/validation.ts
import { z } from 'zod'

export const upgradeRequestSchema = z.object({
  newPlanId: z.string().min(1),
  newPriceId: z.string().optional(),
  billingInterval: z.enum(['month', 'year']).optional()
})

export function validateRequest<T>(schema: z.ZodSchema<T>, data: unknown): T {
  try {
    return schema.parse(data)
  } catch (error) {
    throw new APIError('Invalid request data', 400, 'VALIDATION_ERROR')
  }
}
```

### Usage in Routes

```typescript
export async function POST(req: Request) {
  try {
    const body = await req.json()
    const validatedData = validateRequest(upgradeRequestSchema, body)
    
    // Use validatedData.newPlanId, etc.
  } catch (error) {
    return handleAPIError(error)
  }
}
```

## Rate Limiting

```typescript
// lib/rate-limiting.ts
import { Ratelimit } from '@upstash/ratelimit'
import { Redis } from '@upstash/redis'

const redis = new Redis({
  url: process.env.UPSTASH_REDIS_REST_URL!,
  token: process.env.UPSTASH_REDIS_REST_TOKEN!,
})

const ratelimit = new Ratelimit({
  redis: redis,
  limiter: Ratelimit.slidingWindow(10, '1 m'), // 10 requests per minute
})

export async function checkRateLimit(identifier: string) {
  const { success, limit, reset, remaining } = await ratelimit.limit(identifier)
  
  if (!success) {
    throw new APIError('Rate limit exceeded', 429, 'RATE_LIMIT_EXCEEDED')
  }
  
  return { limit, reset, remaining }
}
```

## Testing API Routes

### Unit Testing

```typescript
// __tests__/api/billing/upgrade.test.ts
import { POST } from '@/app/api/billing/upgrade/route'
import { Request } from 'next/server'

describe('/api/billing/upgrade', () => {
  it('should require authentication', async () => {
    const request = new Request('http://localhost:3000/api/billing/upgrade', {
      method: 'POST',
      body: JSON.stringify({ newPlanId: 'pro' })
    })
    
    const response = await POST(request)
    const data = await response.json()
    
    expect(response.status).toBe(401)
    expect(data.error).toBe('Unauthorized')
  })
  
  it('should validate required fields', async () => {
    // Mock authenticated user
    const request = new Request('http://localhost:3000/api/billing/upgrade', {
      method: 'POST',
      body: JSON.stringify({}) // Missing newPlanId
    })
    
    const response = await POST(request)
    const data = await response.json()
    
    expect(response.status).toBe(400)
    expect(data.error).toBe('Missing newPlanId')
  })
})
```

## Next Steps

In the next module, we'll cover checkout session creation and payment flow implementation.

## Key Takeaways

- Separate user context and service role authentication clearly
- Implement proper input validation and error handling
- Use business logic functions to keep API routes clean
- Handle complex upgrade scenarios with appropriate logic
- Implement comprehensive webhook signature verification
- Structure APIs for maintainability and testing
- Use standardized error responses across all endpoints
