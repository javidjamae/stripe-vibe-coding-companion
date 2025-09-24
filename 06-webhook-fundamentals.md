# Webhook Fundamentals

## Overview

This module covers Stripe webhook implementation fundamentals, including signature verification, event handling, and security best practices. Webhooks are critical for keeping your database in sync with Stripe and handling subscription lifecycle events.

## Webhook Architecture

Your codebase implements a robust webhook handling system:

```
Stripe → Webhook Endpoint → Signature Verification → Event Routing → Database Updates
```

### Main Webhook Handler (Framework-Agnostic)

Our recommended approach provides a clean, framework-agnostic webhook handler:

```typescript
// webhooks/stripe.ts
import Stripe from 'stripe'
import { createServerServiceRoleClient } from './lib/supabase-clients'
import { 
  handleInvoicePaymentPaid,
  handleSubscriptionScheduleCreated,
  handleSubscriptionScheduleUpdated,
  handleSubscriptionScheduleReleased
} from './webhook-handlers'

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
  apiVersion: '2025-08-27.basil'
})

const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET!

export async function handleStripeWebhook(request: Request): Promise<Response> {
  console.log('🚀 Webhook handler started')
  
  try {
    const body = await request.text()
    const signature = request.headers.get('stripe-signature')

    if (!signature) {
      console.log('❌ Missing stripe-signature header')
      return new Response(
        JSON.stringify({ error: 'Missing stripe-signature header' }),
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
        JSON.stringify({ error: 'Invalid signature' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    console.log('👋🏼 Received Stripe webhook event:', event.type)

    // Log lightweight event snapshot for debugging
    const object = event.data?.object ?? null
    if (object) {
      console.log('Object type:', object.object)
      console.log('Object ID:', object.id)
    }

    // Route to specific handlers
    switch (event.type) {
      case 'invoice.payment_succeeded':
        await handleInvoicePaymentPaid(event.data.object)
        break
      
      case 'subscription_schedule.created':
        await handleSubscriptionScheduleCreated(event.data.object)
        break
      
      case 'customer.subscription.updated':
        await handleSubscriptionUpdated(event.data.object)
        break
      
      case 'customer.subscription.deleted':
        await handleSubscriptionDeleted(event.data.object)
        break
      
      case 'invoice.payment_succeeded':
        await handleInvoicePaymentPaid(event.data.object)
        break
      
      case 'invoice.payment_failed':
        await handleInvoicePaymentFailed(event.data.object)
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

## Signature Verification

Critical security measure to ensure webhooks come from Stripe:

### Why Signature Verification Matters

Without verification, anyone could send fake webhook events to your endpoint:
- Fake subscription activations
- Fraudulent payment confirmations
- Malicious data manipulation

### Implementation Pattern

```typescript
// Signature verification implementation
try {
  const body = await request.text()  // Must be raw text, not JSON
  const signature = request.headers.get('stripe-signature')
  
  if (!signature) {
    throw new Error('Missing stripe-signature header')
  }

  // Stripe verifies the signature using your webhook secret
  const event = stripe.webhooks.constructEvent(body, signature, webhookSecret)
  
  // Only process verified events
  await processWebhookEvent(event)
  
} catch (err) {
  console.error('❌ Webhook signature verification failed:', err)
  return new Response(
      JSON.stringify({ error: 'Invalid signature' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
}
```

### Common Signature Verification Issues

1. **Using parsed JSON instead of raw body**
   ```typescript
   // ❌ Wrong - will fail verification
   const body = JSON.stringify(await request.json())
   
   // ✅ Correct - use raw request body
   const body = await request.text()
   ```

2. **Missing or incorrect webhook secret**
   ```typescript
   // Ensure webhook secret matches Stripe dashboard
   const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET!
   if (!webhookSecret) {
     throw new Error('STRIPE_WEBHOOK_SECRET environment variable is required')
   }
   ```

3. **Incorrect endpoint URL in Stripe dashboard**
   - Development: Use Stripe CLI forwarding
   - Production: Ensure HTTPS endpoint is correctly configured

## Event Handling Patterns

### Service Role Client Usage

Webhooks use service role client to bypass RLS:

```typescript
// Webhooks need service role access
const supabase = createServerServiceRoleClient()

// This bypasses RLS policies for system operations
const { data, error } = await supabase
  .from('subscriptions')
  .update({ status: 'active' })
  .eq('stripe_subscription_id', subscriptionId)
```

### Event Handler Structure

```typescript
// handlers.ts
export async function handleInvoicePaymentPaid(invoice: any) {
  console.log('📝 Processing invoice_payment.paid')
  console.log('Invoice ID:', invoice.id)
  console.log('Subscription ID:', invoice.subscription)
  console.log('Amount Paid:', invoice.amount_paid)

  if (!invoice.subscription) {
    console.log('❌ No subscription ID found in invoice')
    return
  }

  try {
    const supabase = createServerServiceRoleClient()
    
    // Update subscription status and billing period
    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        status: 'active',
        current_period_start: isoOrNull(invoice.period_start as number | null),
        current_period_end: isoOrNull(invoice.period_end as number | null),
        updated_at: new Date().toISOString(),
      })
      .eq('stripe_subscription_id', invoice.subscription)
      .select()
      .single()

    if (error) {
      console.error('❌ Error updating subscription:', error)
      return
    }

    console.log(`✅ Successfully updated subscription ${invoice.subscription}`)
    return data
  } catch (error) {
    console.error('❌ Exception in handleInvoicePaymentPaid:', error)
  }
}
```

## Critical Webhook Events

### 1. checkout.session.completed

Triggered when a customer completes checkout:

```typescript
export async function handleCheckoutSessionCompleted(session: any) {
  console.log('🛒 Processing checkout.session.completed')
  
  const customerId = session.customer
  const subscriptionId = session.subscription
  const metadata = session.metadata || {}
  
  if (!subscriptionId) {
    console.log('❌ No subscription in checkout session')
    return
  }

  try {
    // Get subscription details from Stripe
    const subscription = await stripe.subscriptions.retrieve(subscriptionId)
    
    // Create or update subscription in database
    const { data, error } = await supabase
      .from('subscriptions')
      .upsert({
        user_id: metadata.userId,
        stripe_subscription_id: subscriptionId,
        stripe_customer_id: customerId,
        stripe_price_id: subscription.items.data[0].price.id,
        plan_id: metadata.planId,
        status: subscription.status,
        current_period_start: new Date(subscription.current_period_start * 1000).toISOString(),
        current_period_end: new Date(subscription.current_period_end * 1000).toISOString(),
        cancel_at_period_end: subscription.cancel_at_period_end,
        updated_at: new Date().toISOString()
      })
      .select()
      .single()

    if (error) {
      console.error('❌ Error creating subscription:', error)
      return
    }

    console.log('✅ Subscription created successfully')
    return data
  } catch (error) {
    console.error('❌ Exception in handleCheckoutSessionCompleted:', error)
  }
}
```

### 2. customer.subscription.updated

Handles subscription changes:

```typescript
export async function handleSubscriptionUpdated(subscription: any) {
  console.log('📋 Processing customer.subscription.updated')
  
  try {
    const supabase = createServerServiceRoleClient()
    
    // Update subscription details
    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        status: subscription.status,
        stripe_price_id: subscription.items.data[0].price.id,
        current_period_start: new Date(subscription.current_period_start * 1000).toISOString(),
        current_period_end: new Date(subscription.current_period_end * 1000).toISOString(),
        cancel_at_period_end: subscription.cancel_at_period_end,
        updated_at: new Date().toISOString()
      })
      .eq('stripe_subscription_id', subscription.id)
      .select()
      .single()

    if (error) {
      console.error('❌ Error updating subscription:', error)
      return
    }

    console.log('✅ Subscription updated successfully')
    return data
  } catch (error) {
    console.error('❌ Exception in handleSubscriptionUpdated:', error)
  }
}
```

### 3. invoice.payment_failed

Handles failed payments:

```typescript
export async function handleInvoicePaymentFailed(invoice: any) {
  console.log('💳 Processing invoice.payment_failed')
  
  if (!invoice.subscription) {
    console.log('❌ No subscription ID found')
    return
  }

  try {
    const supabase = createServerServiceRoleClient()
    
    // Update subscription status to past_due
    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        status: 'past_due',
        updated_at: new Date().toISOString()
      })
      .eq('stripe_subscription_id', invoice.subscription)
      .select()
      .single()

    if (error) {
      console.error('❌ Error updating subscription status:', error)
      return
    }

    // Optionally send notification to user
    await sendPaymentFailedNotification(data.user_id, invoice)

    console.log('✅ Subscription marked as past_due')
    return data
  } catch (error) {
    console.error('❌ Exception in handleInvoicePaymentFailed:', error)
  }
}
```

## Subscription Schedule Events

Your codebase handles complex subscription schedule events:

### subscription_schedule.created

```typescript
export async function handleSubscriptionScheduleCreated(schedule: any) {
  console.log('📅 Processing subscription_schedule.created')
  
  const subscriptionId = schedule.subscription
  
  if (!subscriptionId) {
    console.log('❌ No subscription ID found')
    return
  }

  try {
    const supabase = createServerServiceRoleClient()
    
    // Check if this is an interval switch from upgrade flow
    const metadata = schedule?.metadata || {}
    const isUpgradeIntervalSwitch = metadata['ffm_interval_switch'] === '1'

    if (isUpgradeIntervalSwitch) {
      // Don't set cancel_at_period_end for interval switches
      console.log('📅 Skipping cancel_at_period_end for interval switch')
      return
    }

    // For regular downgrades, mark subscription as scheduled for cancellation
    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        cancel_at_period_end: true,
        updated_at: new Date().toISOString(),
      })
      .eq('stripe_subscription_id', subscriptionId)
      .select()
      .single()

    if (error) {
      console.error('❌ Error updating subscription:', error)
      return
    }

    console.log('✅ Subscription marked for scheduled downgrade')
    return data
  } catch (error) {
    console.error('❌ Exception in handleSubscriptionScheduleCreated:', error)
  }
}
```

### subscription_schedule.updated

```typescript
export async function handleSubscriptionScheduleUpdated(schedule: any) {
  console.log('📅 Processing subscription_schedule.updated')
  
  try {
    const subscriptionId = schedule.subscription
    const phases = schedule?.phases || []
    const currentPhaseStart = schedule?.current_phase?.start_date

    if (!subscriptionId || !phases.length || !currentPhaseStart) {
      return
    }

    const currentIndex = phases.findIndex(p => p?.start_date === currentPhaseStart)
    
    // When entering phase 2, clear scheduled change metadata
    if (currentIndex >= 1) {
      const supabase = createServerServiceRoleClient()
      
      const { data: row, error: readErr } = await supabase
        .from('subscriptions')
        .select('id, metadata')
        .eq('stripe_subscription_id', subscriptionId)
        .single()
        
      if (readErr) {
        console.error('❌ Error reading subscription:', readErr)
        return
      }

      const currentMeta = (row?.metadata || {}) as Record<string, any>
      if (currentMeta && 'scheduled_change' in currentMeta) {
        const nextMeta = { ...currentMeta }
        delete nextMeta.scheduled_change

        const { error: updErr } = await supabase
          .from('subscriptions')
          .update({ 
            metadata: nextMeta, 
            updated_at: new Date().toISOString() 
          })
          .eq('id', row!.id)
          
        if (updErr) {
          console.error('❌ Error clearing scheduled_change metadata:', updErr)
          return
        }
        
        console.log(`✅ Cleared scheduled_change for subscription ${subscriptionId}`)
      }
    }
  } catch (error) {
    console.error('❌ Exception in handleSubscriptionScheduleUpdated:', error)
  }
}
```

## Error Handling and Retry Logic

### Webhook Retry Strategy

Stripe automatically retries failed webhooks:
- Initial failure: Retry immediately
- Subsequent failures: Exponential backoff
- Final attempt: After 3 days

### Idempotency Handling

```typescript
// Track processed events to prevent duplicate processing
const processedEvents = new Set<string>()

export async function processWebhookEvent(event: Stripe.Event) {
  // Check if event already processed
  if (processedEvents.has(event.id)) {
    console.log(`Event ${event.id} already processed, skipping`)
    return
  }

  try {
    await handleEvent(event)
    
    // Mark as processed
    processedEvents.add(event.id)
    
    // Optional: Store in database for persistence
    await storeProcessedEvent(event.id)
    
  } catch (error) {
    console.error(`Failed to process event ${event.id}:`, error)
    throw error // Let Stripe retry
  }
}
```

### Database-Based Idempotency

```sql
-- Create table to track processed webhook events
CREATE TABLE webhook_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_event_id TEXT UNIQUE NOT NULL,
  event_type TEXT NOT NULL,
  processed_at TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index for fast lookups
CREATE INDEX idx_webhook_events_stripe_id ON webhook_events(stripe_event_id);
```

```typescript
async function isEventProcessed(eventId: string): Promise<boolean> {
  const { data, error } = await supabase
    .from('webhook_events')
    .select('id')
    .eq('stripe_event_id', eventId)
    .single()

  return !error && !!data
}

async function markEventProcessed(event: Stripe.Event): Promise<void> {
  await supabase
    .from('webhook_events')
    .insert({
      stripe_event_id: event.id,
      event_type: event.type,
    })
}
```

## Development and Testing

### Local Webhook Testing with Stripe CLI

```bash
# Install Stripe CLI
brew install stripe/stripe-cli/stripe

# Login to your Stripe account
stripe login

# Forward webhooks to local development server
stripe listen --forward-to localhost:3000/api/webhooks/stripe

# This will output a webhook signing secret like:
# whsec_1234567890abcdef...
# Add this to your .env.local as STRIPE_WEBHOOK_SECRET
```

### Triggering Test Events

```bash
# Trigger specific webhook events for testing
stripe trigger checkout.session.completed
stripe trigger customer.subscription.created
stripe trigger invoice.payment_succeeded
stripe trigger invoice.payment_failed
```

### Webhook Testing in CI/CD

```typescript
// __tests__/webhooks/stripe-webhook.test.ts
import { POST } from '@/app/api/webhooks/stripe/route'
import { Request } from 'next/server'
import Stripe from 'stripe'

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
  apiVersion: '2025-08-27.basil'
})

describe('Stripe Webhook Handler', () => {
  it('should handle checkout.session.completed', async () => {
    // Create test event
    const event = {
      id: 'evt_test_webhook',
      type: 'checkout.session.completed',
      data: {
        object: {
          id: 'cs_test_123',
          customer: 'cus_test_123',
          subscription: 'sub_test_123',
          metadata: {
            userId: 'user_test_123',
            planId: 'starter'
          }
        }
      }
    }

    // Create webhook signature
    const payload = JSON.stringify(event)
    const signature = stripe.webhooks.generateTestHeaderString({
      payload,
      secret: process.env.STRIPE_WEBHOOK_SECRET!
    })

    // Create request
    const request = new Request('http://localhost:3000/api/webhooks/stripe', {
      method: 'POST',
      body: payload,
      headers: {
        'stripe-signature': signature,
        'content-type': 'application/json'
      }
    })

    // Process webhook
    const response = await POST(request)
    const result = await response.json()

    expect(response.status).toBe(200)
    expect(result.received).toBe(true)
  })
})
```

## Monitoring and Alerting

### Webhook Event Logging

```typescript
// Enhanced logging for webhook events
export async function logWebhookEvent(event: Stripe.Event, success: boolean, error?: Error) {
  const logEntry = {
    event_id: event.id,
    event_type: event.type,
    success,
    error_message: error?.message,
    processing_time: Date.now() - event.created * 1000,
    created_at: new Date().toISOString()
  }

  // Log to your monitoring service
  if (process.env.NODE_ENV === 'production') {
    await monitoringService.log('webhook_processed', logEntry)
  }

  console.log('Webhook processed:', logEntry)
}
```

### Webhook Health Monitoring

```typescript
// app/api/admin/webhook-health/route.ts
export async function GET() {
  const supabase = createServerServiceRoleClient()
  
  // Check recent webhook processing
  const { data: recentEvents, error } = await supabase
    .from('webhook_events')
    .select('*')
    .gte('created_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()) // Last 24 hours
    .order('created_at', { ascending: false })
    .limit(100)

  if (error) {
    return new Response(
      JSON.stringify({ error: 'Failed to fetch webhook events' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }

  const stats = {
    total_events: recentEvents.length,
    event_types: recentEvents.reduce((acc, event) => {
      acc[event.event_type] = (acc[event.event_type] || 0) + 1
      return acc
    }, {} as Record<string, number>),
    last_event_at: recentEvents[0]?.created_at,
    health_status: recentEvents.length > 0 ? 'healthy' : 'no_recent_events'
  }

  return new Response(
      JSON.stringify(stats)
}
```

## Next Steps

In the next module, we'll cover subscription creation and the complete flow from checkout to active subscription.

## Key Takeaways

- Always verify webhook signatures for security
- Use service role client for webhook database operations
- Implement idempotency to handle duplicate events
- Handle all critical subscription lifecycle events
- Use Stripe CLI for local development and testing
- Implement comprehensive error handling and retry logic
- Monitor webhook health and processing times
- Store processed event IDs to prevent duplicates
- Log webhook events for debugging and analytics
