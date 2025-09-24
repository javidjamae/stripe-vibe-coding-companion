# Testing Webhook Handlers and Failure Scenarios

## Overview

This module covers testing webhook handlers, simulating webhook events, and testing failure scenarios. Based on your codebase patterns, we'll explore webhook testing strategies that ensure reliable billing system behavior.

## Your Webhook Testing Architecture

Your codebase implements webhook testing through:

1. **Direct Handler Testing**: Call webhook handlers directly in tests
2. **Mock Event Payloads**: Create realistic Stripe event objects
3. **Database Verification**: Assert database state changes
4. **Error Simulation**: Test webhook failure scenarios

## Webhook Handler Testing (Your Actual Implementation)

### Testing Invoice Payment Success

From your actual webhook tests:

```typescript
// Your actual webhook handler tests
describe('Stripe Webhook Handlers', () => {
  describe('handleInvoicePaymentPaid', () => {
    it('should update subscription status to active', async () => {
      // Create test subscription
      const { data: subscription } = await testSupabase
        .from('subscriptions')
        .insert({
          user_id: testUserId,
          stripe_subscription_id: 'sub_test_123',
          plan_id: 'starter',
          status: 'incomplete'
        })
        .select()
        .single()

      // Create mock invoice payload
      const mockInvoice = {
        id: 'in_test_123',
        subscription: 'sub_test_123',
        amount_paid: 1900,
        currency: 'usd',
        status: 'paid',
        period_start: Math.floor(Date.now() / 1000),
        period_end: Math.floor(Date.now() / 1000) + 2592000 // 30 days
      }

      // Call handler directly
      const { handleInvoicePaymentPaid } = await import('@/app/api/webhooks/stripe/handlers')
      const result = await handleInvoicePaymentPaid(mockInvoice)

      // Verify database was updated
      const { data: updatedSub } = await testSupabase
        .from('subscriptions')
        .select('*')
        .eq('id', subscription.id)
        .single()

      expect(updatedSub.status).toBe('active')
      expect(updatedSub.current_period_start).toBeTruthy()
      expect(updatedSub.current_period_end).toBeTruthy()
    })
  })
})
```

### Testing Subscription Schedule Events

```typescript
// Testing your actual subscription schedule handlers
describe('Subscription Schedule Handlers', () => {
  describe('handleSubscriptionScheduleCreated', () => {
    it('should set cancel_at_period_end for downgrade schedules', async () => {
      // Create test subscription
      const { data: subscription } = await testSupabase
        .from('subscriptions')
        .insert({
          user_id: testUserId,
          stripe_subscription_id: 'sub_test_456',
          plan_id: 'starter',
          status: 'active',
          cancel_at_period_end: false
        })
        .select()
        .single()

      // Mock schedule created event (downgrade scenario)
      const mockSchedule = {
        id: 'sub_sched_test_123',
        subscription: 'sub_test_456',
        metadata: {} // No interval switch metadata = downgrade
      }

      // Call handler
      const { handleSubscriptionScheduleCreated } = await import('@/app/api/webhooks/stripe/handlers')
      await handleSubscriptionScheduleCreated(mockSchedule)

      // Verify cancel_at_period_end was set
      const { data: updated } = await testSupabase
        .from('subscriptions')
        .select('cancel_at_period_end')
        .eq('id', subscription.id)
        .single()

      expect(updated.cancel_at_period_end).toBe(true)
    })

    it('should skip cancel_at_period_end for interval switch schedules', async () => {
      // Create test subscription
      const { data: subscription } = await testSupabase
        .from('subscriptions')
        .insert({
          user_id: testUserId,
          stripe_subscription_id: 'sub_test_789',
          plan_id: 'pro',
          status: 'active',
          cancel_at_period_end: false,
          metadata: {
            scheduled_change: {
              interval: 'month' // Indicates interval switch
            }
          }
        })
        .select()
        .single()

      // Mock schedule created event (interval switch scenario)
      const mockSchedule = {
        id: 'sub_sched_test_456',
        subscription: 'sub_test_789',
        metadata: {
          ffm_interval_switch: '1',
          ffm_target_interval: 'month'
        }
      }

      // Call handler
      const { handleSubscriptionScheduleCreated } = await import('@/app/api/webhooks/stripe/handlers')
      await handleSubscriptionScheduleCreated(mockSchedule)

      // Verify cancel_at_period_end was NOT set
      const { data: updated } = await testSupabase
        .from('subscriptions')
        .select('cancel_at_period_end')
        .eq('id', subscription.id)
        .single()

      expect(updated.cancel_at_period_end).toBe(false)
    })
  })
})
```

## Mock Event Payload Creation

### Realistic Event Payloads

```typescript
// cypress/fixtures/stripe-events.ts
export const StripeEventFixtures = {
  invoicePaymentPaid: (subscriptionId: string, customOptions: any = {}) => ({
    id: `in_test_${Date.now()}`,
    object: 'invoice',
    subscription: subscriptionId,
    customer: customOptions.customerId || `cus_test_${Date.now()}`,
    amount_paid: customOptions.amount || 1900,
    currency: 'usd',
    status: 'paid',
    period_start: customOptions.periodStart || Math.floor(Date.now() / 1000),
    period_end: customOptions.periodEnd || Math.floor(Date.now() / 1000) + 2592000,
    lines: {
      data: [{
        id: `il_test_${Date.now()}`,
        amount: customOptions.amount || 1900,
        description: customOptions.description || 'Starter Plan',
        period: {
          start: customOptions.periodStart || Math.floor(Date.now() / 1000),
          end: customOptions.periodEnd || Math.floor(Date.now() / 1000) + 2592000
        }
      }]
    }
  }),

  subscriptionScheduleCreated: (subscriptionId: string, isIntervalSwitch: boolean = false) => ({
    id: `sub_sched_test_${Date.now()}`,
    object: 'subscription_schedule',
    subscription: subscriptionId,
    status: 'active',
    metadata: isIntervalSwitch ? {
      ffm_interval_switch: '1',
      ffm_target_interval: 'month'
    } : {},
    current_phase: {
      start_date: Math.floor(Date.now() / 1000),
      end_date: Math.floor(Date.now() / 1000) + 2592000
    }
  }),

  subscriptionScheduleReleased: (subscriptionId: string) => ({
    id: `sub_sched_test_${Date.now()}`,
    object: 'subscription_schedule',
    released_subscription: subscriptionId,
    status: 'released'
  })
}
```

### Event Factory Usage

```typescript
// Using event fixtures in tests
describe('Webhook Event Processing', () => {
  it('should process invoice payment paid event', async () => {
    const testSubscriptionId = 'sub_test_webhook_123'
    
    // Create test subscription
    await testSupabase.from('subscriptions').insert({
      user_id: testUserId,
      stripe_subscription_id: testSubscriptionId,
      plan_id: 'starter',
      status: 'incomplete'
    })

    // Create realistic event payload
    const invoiceEvent = StripeEventFixtures.invoicePaymentPaid(testSubscriptionId, {
      amount: 1900,
      description: 'Starter Plan - Monthly'
    })

    // Test the handler
    const { handleInvoicePaymentPaid } = await import('@/app/api/webhooks/stripe/handlers')
    await handleInvoicePaymentPaid(invoiceEvent)

    // Verify results
    const { data: updated } = await testSupabase
      .from('subscriptions')
      .select('status, current_period_start, current_period_end')
      .eq('stripe_subscription_id', testSubscriptionId)
      .single()

    expect(updated.status).toBe('active')
    expect(updated.current_period_start).toBeTruthy()
    expect(updated.current_period_end).toBeTruthy()
  })
})
```

## Webhook Failure Testing

### Error Scenario Testing

```typescript
// Testing webhook handler error scenarios
describe('Webhook Error Handling', () => {
  it('should handle missing subscription ID gracefully', async () => {
    const mockInvoiceWithoutSub = {
      id: 'in_test_no_sub',
      subscription: null, // Missing subscription ID
      amount_paid: 1900,
      status: 'paid'
    }

    // Should not throw error
    const { handleInvoicePaymentPaid } = await import('@/app/api/webhooks/stripe/handlers')
    const result = await handleInvoicePaymentPaid(mockInvoiceWithoutSub)

    // Should return early without database changes
    expect(result).toBeUndefined()
  })

  it('should handle database errors gracefully', async () => {
    // Mock database error by using invalid subscription ID
    const mockInvoice = {
      id: 'in_test_db_error',
      subscription: 'sub_nonexistent_123',
      amount_paid: 1900,
      status: 'paid',
      period_start: Math.floor(Date.now() / 1000),
      period_end: Math.floor(Date.now() / 1000) + 2592000
    }

    // Should handle gracefully and not throw
    const { handleInvoicePaymentPaid } = await import('@/app/api/webhooks/stripe/handlers')
    
    // Should not throw, but should log error
    const consoleSpy = jest.spyOn(console, 'error').mockImplementation()
    await handleInvoicePaymentPaid(mockInvoice)
    
    expect(consoleSpy).toHaveBeenCalledWith(
      expect.stringContaining('Error updating subscription')
    )
    
    consoleSpy.mockRestore()
  })
})
```

## Webhook Simulation in E2E Tests

### Simulating Webhook Events

```typescript
// cypress/tasks/webhook-simulation.ts
export async function simulateWebhookEvent(eventType: string, payload: any) {
  console.log(`🔄 Simulating webhook event: ${eventType}`)
  
  try {
    // Import the appropriate handler
    const handlers = await import('../../../app/api/webhooks/stripe/handlers')
    
    switch (eventType) {
      case 'invoice.payment_succeeded':
        await handlers.handleInvoicePaymentPaid(payload)
        break
        
      case 'subscription_schedule.created':
        await handlers.handleSubscriptionScheduleCreated(payload)
        break
        
      case 'subscription_schedule.updated':
        await handlers.handleSubscriptionScheduleUpdated(payload)
        break
        
      case 'subscription_schedule.released':
        await handlers.handleSubscriptionScheduleReleased(payload)
        break
        
      default:
        throw new Error(`Unsupported webhook event type: ${eventType}`)
    }
    
    console.log('✅ Webhook simulation completed')
    return { ok: true }

  } catch (error) {
    console.error('❌ Webhook simulation failed:', error)
    return { 
      ok: false, 
      error: error instanceof Error ? error.message : 'Unknown error' 
    }
  }
}
```

### Using Webhook Simulation in Tests

```typescript
// cypress/e2e/billing/webhook-integration.cy.ts
describe('Webhook Integration', () => {
  const email = `webhook-test-${Date.now()}@example.com`

  beforeEach(() => {
    cy.task('seedStarterUserWithStripeSubscription', { email })
  })

  it('should process subscription schedule release webhook', () => {
    // First, create a scheduled downgrade
    cy.login(email)
    cy.visit('/billing')
    
    // Schedule downgrade to free
    cy.get('[data-testid="free-action-button"]').click()
    cy.get('[data-testid="downgrade-modal"]').should('be.visible')
    cy.get('[data-testid="confirm-downgrade-button"]').click()
    
    // Verify scheduled change is shown
    cy.get('[data-testid="current-plan-name"]').should('contain', 'Downgrading')
    
    // Now simulate webhook that cancels the schedule
    cy.task('getSubscriptionForEmail', email).then((result: any) => {
      const subscriptionId = result.subscription.stripe_subscription_id
      
      // Simulate schedule released webhook
      cy.task('simulateWebhookEvent', {
        eventType: 'subscription_schedule.released',
        payload: {
          id: 'sub_sched_test_123',
          released_subscription: subscriptionId
        }
      })
    })
    
    // Reload page and verify scheduled change is cleared
    cy.reload()
    cy.get('[data-testid="current-plan-name"]').should('not.contain', 'Downgrading')
    cy.get('[data-testid="current-plan-name"]').should('contain', 'Starter')
  })
})
```

## Webhook Route Testing

### Testing Complete Webhook Flow

```typescript
// __tests__/api/webhooks/stripe-webhook.test.ts
import { createMocks } from 'node-mocks-http'
import { POST } from '@/app/api/webhooks/stripe/route'

describe('/api/webhooks/stripe', () => {
  it('should process invoice.payment_succeeded webhook', async () => {
    // Create test subscription
    const { data: subscription } = await testSupabase
      .from('subscriptions')
      .insert({
        user_id: testUserId,
        stripe_subscription_id: 'sub_webhook_test',
        plan_id: 'starter',
        status: 'incomplete'
      })
      .select()
      .single()

    // Create webhook event payload
    const webhookEvent = {
      id: 'evt_test_webhook',
      type: 'invoice.payment_succeeded',
      data: {
        object: {
          id: 'in_test_webhook',
          subscription: 'sub_webhook_test',
          amount_paid: 1900,
          currency: 'usd',
          status: 'paid',
          period_start: Math.floor(Date.now() / 1000),
          period_end: Math.floor(Date.now() / 1000) + 2592000
        }
      },
      created: Math.floor(Date.now() / 1000)
    }

    // Create mock request with proper signature
    const body = JSON.stringify(webhookEvent)
    const signature = createTestWebhookSignature(body)
    
    const { req } = createMocks({
      method: 'POST',
      headers: {
        'stripe-signature': signature,
        'content-type': 'application/json'
      },
      body: body
    })

    // Mock request.text() to return the body
    req.text = jest.fn().mockResolvedValue(body)

    // Call webhook endpoint
    const response = await POST(req as any)
    const responseData = await response.json()

    // Verify response
    expect(response.status).toBe(200)
    expect(responseData.received).toBe(true)

    // Verify database was updated
    const { data: updated } = await testSupabase
      .from('subscriptions')
      .select('status')
      .eq('id', subscription.id)
      .single()

    expect(updated.status).toBe('active')
  })
})
```

### Webhook Signature Testing

```typescript
// Testing webhook signature verification
function createTestWebhookSignature(payload: string): string {
  const crypto = require('crypto')
  const secret = process.env.STRIPE_WEBHOOK_SECRET!
  const timestamp = Math.floor(Date.now() / 1000)
  
  const signedPayload = `${timestamp}.${payload}`
  const signature = crypto
    .createHmac('sha256', secret)
    .update(signedPayload, 'utf8')
    .digest('hex')
    
  return `t=${timestamp},v1=${signature}`
}

describe('Webhook Signature Verification', () => {
  it('should reject webhooks with invalid signatures', async () => {
    const body = JSON.stringify({ type: 'test.event' })
    
    const { req } = createMocks({
      method: 'POST',
      headers: {
        'stripe-signature': 'invalid_signature',
        'content-type': 'application/json'
      }
    })

    req.text = jest.fn().mockResolvedValue(body)

    const response = await POST(req as any)
    
    expect(response.status).toBe(400)
    
    const responseData = await response.json()
    expect(responseData.error).toContain('Invalid signature')
  })

  it('should accept webhooks with valid signatures', async () => {
    const webhookEvent = { type: 'test.event', data: { object: {} } }
    const body = JSON.stringify(webhookEvent)
    const validSignature = createTestWebhookSignature(body)
    
    const { req } = createMocks({
      method: 'POST',
      headers: {
        'stripe-signature': validSignature,
        'content-type': 'application/json'
      }
    })

    req.text = jest.fn().mockResolvedValue(body)

    const response = await POST(req as any)
    
    expect(response.status).toBe(200)
  })
})
```

## Testing Webhook Idempotency

### Duplicate Event Handling

```typescript
// Testing idempotency of webhook handlers
describe('Webhook Idempotency', () => {
  it('should handle duplicate invoice.payment_succeeded events', async () => {
    // Create test subscription
    const { data: subscription } = await testSupabase
      .from('subscriptions')
      .insert({
        user_id: testUserId,
        stripe_subscription_id: 'sub_idempotent_test',
        plan_id: 'starter',
        status: 'incomplete'
      })
      .select()
      .single()

    const mockInvoice = {
      id: 'in_idempotent_test',
      subscription: 'sub_idempotent_test',
      amount_paid: 1900,
      status: 'paid',
      period_start: Math.floor(Date.now() / 1000),
      period_end: Math.floor(Date.now() / 1000) + 2592000
    }

    const { handleInvoicePaymentPaid } = await import('@/app/api/webhooks/stripe/handlers')

    // Process the same event twice
    await handleInvoicePaymentPaid(mockInvoice)
    await handleInvoicePaymentPaid(mockInvoice)

    // Verify subscription is still in correct state
    const { data: updated } = await testSupabase
      .from('subscriptions')
      .select('status, updated_at')
      .eq('id', subscription.id)
      .single()

    expect(updated.status).toBe('active')
    
    // Should not have caused any errors or inconsistent state
    // (Your handlers are naturally idempotent due to Stripe ID matching)
  })
})
```

## Webhook Error Recovery Testing

### Database Error Scenarios

```typescript
// Testing webhook behavior when database is unavailable
describe('Webhook Error Recovery', () => {
  it('should handle database connection failures', async () => {
    // Mock database error
    const originalSupabase = require('@/lib/supabase-clients')
    const mockSupabase = {
      from: jest.fn(() => ({
        update: jest.fn(() => ({
          eq: jest.fn(() => ({
            select: jest.fn(() => ({
              single: jest.fn(() => Promise.resolve({ 
                data: null, 
                error: { message: 'Database connection failed' } 
              }))
            }))
          }))
        }))
      }))
    }

    // Mock the supabase client
    jest.doMock('@/lib/supabase-clients', () => ({
      createServerServiceRoleClient: () => mockSupabase
    }))

    const mockInvoice = {
      id: 'in_db_error_test',
      subscription: 'sub_db_error_test',
      amount_paid: 1900,
      status: 'paid',
      period_start: Math.floor(Date.now() / 1000),
      period_end: Math.floor(Date.now() / 1000) + 2592000
    }

    // Should not throw error
    const { handleInvoicePaymentPaid } = await import('@/app/api/webhooks/stripe/handlers')
    
    const consoleSpy = jest.spyOn(console, 'error').mockImplementation()
    await expect(handleInvoicePaymentPaid(mockInvoice)).resolves.not.toThrow()
    
    // Should log error
    expect(consoleSpy).toHaveBeenCalledWith(
      expect.stringContaining('Error updating subscription')
    )
    
    consoleSpy.mockRestore()
    jest.clearAllMocks()
  })
})
```

## Webhook Performance Testing

### Load Testing Webhook Handlers

```typescript
// Testing webhook handler performance
describe('Webhook Performance', () => {
  it('should handle multiple concurrent webhook events', async () => {
    const startTime = Date.now()
    
    // Create multiple test subscriptions
    const subscriptions = await Promise.all(
      Array.from({ length: 10 }, async (_, i) => {
        const { data } = await testSupabase
          .from('subscriptions')
          .insert({
            user_id: testUserId,
            stripe_subscription_id: `sub_perf_test_${i}`,
            plan_id: 'starter',
            status: 'incomplete'
          })
          .select()
          .single()
        return data
      })
    )

    // Create invoice events for all subscriptions
    const invoiceEvents = subscriptions.map((sub, i) => ({
      id: `in_perf_test_${i}`,
      subscription: sub.stripe_subscription_id,
      amount_paid: 1900,
      status: 'paid',
      period_start: Math.floor(Date.now() / 1000),
      period_end: Math.floor(Date.now() / 1000) + 2592000
    }))

    // Process all events concurrently
    const { handleInvoicePaymentPaid } = await import('@/app/api/webhooks/stripe/handlers')
    
    await Promise.all(
      invoiceEvents.map(event => handleInvoicePaymentPaid(event))
    )

    const endTime = Date.now()
    const duration = endTime - startTime

    // Verify all subscriptions were updated
    const { data: updated } = await testSupabase
      .from('subscriptions')
      .select('status')
      .in('id', subscriptions.map(s => s.id))

    expect(updated).toHaveLength(10)
    expect(updated.every(s => s.status === 'active')).toBe(true)
    
    // Performance assertion (should complete within reasonable time)
    expect(duration).toBeLessThan(5000) // 5 seconds
    
    console.log(`✅ Processed 10 webhook events in ${duration}ms`)
  })
})
```

## Webhook Testing Best Practices

### Test Organization

```typescript
// Organizing webhook tests by event type
describe('Stripe Webhook Handlers', () => {
  describe('Invoice Events', () => {
    describe('invoice.payment_succeeded', () => {
      it('should activate incomplete subscriptions', async () => {
        // Test implementation
      })
      
      it('should update billing period dates', async () => {
        // Test implementation
      })
    })
    
    describe('invoice.payment_failed', () => {
      it('should mark subscription as past_due', async () => {
        // Test implementation (if you implement this handler)
      })
    })
  })

  describe('Subscription Schedule Events', () => {
    describe('subscription_schedule.created', () => {
      it('should handle downgrade schedules', async () => {
        // Test implementation
      })
      
      it('should handle interval switch schedules', async () => {
        // Test implementation
      })
    })
  })
})
```

### Test Data Isolation

```typescript
// Ensuring webhook tests don't interfere with each other
describe('Webhook Handler Tests', () => {
  let testSubscriptionId: string
  let testUserId: string

  beforeEach(async () => {
    // Create fresh test data for each test
    testUserId = `test_user_${Date.now()}`
    testSubscriptionId = `sub_test_${Date.now()}`
    
    await testSupabase.from('subscriptions').insert({
      user_id: testUserId,
      stripe_subscription_id: testSubscriptionId,
      plan_id: 'starter',
      status: 'incomplete'
    })
  })

  afterEach(async () => {
    // Clean up test data
    await testSupabase
      .from('subscriptions')
      .delete()
      .eq('stripe_subscription_id', testSubscriptionId)
  })
})
```

## Alternative: Webhook Testing with Real Stripe Events

If you wanted to test with real Stripe webhook events instead of mocking:

### Stripe CLI Integration

```bash
# Forward webhooks to test endpoint
stripe listen --forward-to localhost:3000/api/webhooks/stripe-test

# Trigger specific events
stripe trigger invoice.payment_succeeded
stripe trigger subscription_schedule.created
```

### Test Webhook Endpoint

```typescript
// app/api/webhooks/stripe-test/route.ts (Alternative approach)
export async function POST(request: Request) {
  // Only allow in test environment
  if (process.env.NODE_ENV === 'production') {
    return new Response(
      JSON.stringify({ error: 'Not available in production' ),
      { status: 403 })
  }

  try {
    const body = await request.text()
    const signature = request.headers.get('stripe-signature')

    if (!signature) {
      return new Response(
      JSON.stringify({ error: 'Missing signature' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    // Verify signature with test webhook secret
    const event = stripe.webhooks.constructEvent(
      body, 
      signature, 
      process.env.STRIPE_TEST_WEBHOOK_SECRET!
    )

    // Process event normally
    await processWebhookEvent(event)

    // Store event for test verification
    await testSupabase
      .from('webhook_test_events')
      .insert({
        event_id: event.id,
        event_type: event.type,
        processed_at: new Date().toISOString(),
        payload: event.data.object
      })

    return new Response(
      JSON.stringify({ received: true, eventId: event.id })

  } catch (error) {
    console.error('Test webhook error:', error)
    return new Response(
      JSON.stringify({ error: 'Webhook processing failed' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Next Steps

In the next module, we'll cover production deployment checklists and validation procedures.

## Key Takeaways

- **Test webhook handlers directly** by calling functions with mock payloads
- **Use realistic event fixtures** that match actual Stripe webhook payloads
- **Test error scenarios** including missing data and database failures
- **Simulate webhook events** in E2E tests to verify complete flows
- **Ensure idempotency** by testing duplicate event processing
- **Test performance** with concurrent webhook event processing
- **Organize tests by event type** for maintainability
- **Use test mode detection** to avoid real Stripe calls in tests
- **Clean up test data** systematically after test runs
- **Verify both success and failure scenarios** for comprehensive coverage
