# Testing Webhook Handlers Thoroughly

## Overview

This module covers comprehensive testing strategies for webhook handlers, including unit testing individual handlers, integration testing with real Stripe events, and testing failure scenarios and edge cases.

## Webhook Testing Strategy

### Testing Pyramid for Webhooks

```
E2E Tests (Few) → Integration Tests (Some) → Unit Tests (Many)
```

### Test Categories

1. **Unit Tests**: Individual handler functions in isolation
2. **Integration Tests**: Full webhook flow with real database
3. **Contract Tests**: Verify Stripe event structure compliance
4. **Failure Tests**: Error scenarios and edge cases
5. **Performance Tests**: Handler performance under load

## Unit Testing Webhook Handlers

### Handler Test Structure

```typescript
// __tests__/webhooks/handlers/invoice-payment-succeeded.test.ts
import { handleInvoicePaymentPaid } from '@/app/api/webhooks/stripe/handlers'

// Mock Supabase
jest.mock('@/lib/supabase-clients')

describe('handleInvoicePaymentPaid', () => {
  let mockSupabase: any

  beforeEach(() => {
    mockSupabase = {
      from: jest.fn(() => ({
        update: jest.fn(() => ({
          eq: jest.fn(() => ({
            select: jest.fn(() => ({
              single: jest.fn()
            }))
          }))
        }))
      }))
    }

    require('@/lib/supabase-clients').createServerServiceRoleClient.mockReturnValue(mockSupabase)
  })

  it('should update subscription status on successful payment', async () => {
    const mockInvoice = {
      id: 'in_test_123',
      subscription: 'sub_test_123',
      amount_paid: 1900,
      currency: 'usd',
      status: 'paid',
      period_start: 1640995200, // Jan 1, 2022
      period_end: 1643673600    // Feb 1, 2022
    }

    mockSupabase.from().update().eq().select().single.mockResolvedValue({
      data: { 
        id: 'sub_db_123', 
        status: 'active',
        current_period_start: '2022-01-01T00:00:00Z',
        current_period_end: '2022-02-01T00:00:00Z'
      },
      error: null
    })

    const result = await handleInvoicePaymentPaid(mockInvoice)

    expect(result).toBeDefined()
    expect(result.id).toBe('sub_db_123')
    expect(mockSupabase.from).toHaveBeenCalledWith('subscriptions')
    expect(mockSupabase.from().update).toHaveBeenCalledWith({
      status: 'active',
      current_period_start: '2022-01-01T00:00:00.000Z',
      current_period_end: '2022-02-01T00:00:00.000Z',
      updated_at: expect.any(String)
    })
  })

  it('should handle missing subscription ID gracefully', async () => {
    const mockInvoice = {
      id: 'in_test_456',
      // No subscription field
      amount_paid: 1900
    }

    const result = await handleInvoicePaymentPaid(mockInvoice)

    expect(result).toBeUndefined()
    expect(mockSupabase.from).not.toHaveBeenCalled()
  })

  it('should handle database errors gracefully', async () => {
    const mockInvoice = {
      id: 'in_test_789',
      subscription: 'sub_test_789',
      amount_paid: 1900,
      period_start: 1640995200,
      period_end: 1643673600
    }

    mockSupabase.from().update().eq().select().single.mockResolvedValue({
      data: null,
      error: { message: 'Database connection failed', code: 'CONNECTION_ERROR' }
    })

    const result = await handleInvoicePaymentPaid(mockInvoice)

    expect(result).toBeUndefined()
    // Should log error but not throw
  })

  it('should handle malformed invoice data', async () => {
    const malformedInvoice = {
      id: 'in_malformed',
      subscription: 'sub_test_123',
      // Missing required fields
      period_start: 'invalid_timestamp',
      period_end: null
    }

    // Should not throw, should handle gracefully
    const result = await handleInvoicePaymentPaid(malformedInvoice)
    
    // Exact behavior depends on your error handling strategy
    expect(result).toBeUndefined()
  })
})
```

### Subscription Schedule Handler Tests

```typescript
// __tests__/webhooks/handlers/subscription-schedule.test.ts
import { 
  handleSubscriptionScheduleCreated,
  handleSubscriptionScheduleUpdated,
  handleSubscriptionScheduleReleased
} from '@/app/api/webhooks/stripe/handlers'

describe('Subscription Schedule Handlers', () => {
  let mockSupabase: any

  beforeEach(() => {
    mockSupabase = {
      from: jest.fn(() => ({
        select: jest.fn(() => ({
          eq: jest.fn(() => ({
            single: jest.fn()
          }))
        })),
        update: jest.fn(() => ({
          eq: jest.fn(() => ({
            select: jest.fn(() => ({
              single: jest.fn()
            }))
          }))
        }))
      }))
    }

    require('@/lib/supabase-clients').createServerServiceRoleClient.mockReturnValue(mockSupabase)
  })

  describe('handleSubscriptionScheduleCreated', () => {
    it('should set cancel_at_period_end for regular downgrades', async () => {
      const mockSchedule = {
        id: 'sub_sched_123',
        subscription: 'sub_test_123',
        metadata: {} // No interval switch indicators
      }

      mockSupabase.from().select().eq().single.mockResolvedValue({
        data: { id: 'sub_db_123', metadata: {} },
        error: null
      })

      mockSupabase.from().update().eq().select().single.mockResolvedValue({
        data: { id: 'sub_db_123', cancel_at_period_end: true },
        error: null
      })

      const result = await handleSubscriptionScheduleCreated(mockSchedule)

      expect(result).toBeDefined()
      expect(mockSupabase.from().update).toHaveBeenCalledWith({
        cancel_at_period_end: true,
        updated_at: expect.any(String)
      })
    })

    it('should skip cancel_at_period_end for interval switch schedules', async () => {
      const mockSchedule = {
        id: 'sub_sched_456',
        subscription: 'sub_test_456',
        metadata: {
          ffm_interval_switch: '1',
          ffm_target_interval: 'month'
        }
      }

      mockSupabase.from().select().eq().single.mockResolvedValue({
        data: { 
          id: 'sub_db_456', 
          metadata: {
            scheduled_change: {
              interval: 'month'
            }
          }
        },
        error: null
      })

      const result = await handleSubscriptionScheduleCreated(mockSchedule)

      expect(result).toBeDefined()
      expect(mockSupabase.from().update).not.toHaveBeenCalled()
    })
  })

  describe('handleSubscriptionScheduleUpdated', () => {
    it('should clear scheduled_change metadata when entering phase 2', async () => {
      const mockSchedule = {
        id: 'sub_sched_789',
        subscription: 'sub_test_789',
        current_phase: {
          start_date: 1643673600 // Feb 1, 2022
        },
        phases: [
          { start_date: 1640995200 }, // Jan 1, 2022 (phase 1)
          { start_date: 1643673600 }  // Feb 1, 2022 (phase 2)
        ]
      }

      mockSupabase.from().select().eq().single.mockResolvedValue({
        data: {
          id: 'sub_db_789',
          metadata: {
            scheduled_change: {
              planId: 'pro',
              interval: 'month',
              effectiveAt: '2022-02-01T00:00:00Z'
            }
          }
        },
        error: null
      })

      mockSupabase.from().update().eq().mockResolvedValue({
        data: null,
        error: null
      })

      await handleSubscriptionScheduleUpdated(mockSchedule)

      expect(mockSupabase.from().update).toHaveBeenCalledWith({
        metadata: {}, // scheduled_change should be cleared
        updated_at: expect.any(String)
      })
    })

    it('should not clear metadata when still in phase 1', async () => {
      const mockSchedule = {
        id: 'sub_sched_101112',
        subscription: 'sub_test_101112',
        current_phase: {
          start_date: 1640995200 // Jan 1, 2022 (still phase 1)
        },
        phases: [
          { start_date: 1640995200 }, // Jan 1, 2022 (phase 1)
          { start_date: 1643673600 }  // Feb 1, 2022 (phase 2)
        ]
      }

      await handleSubscriptionScheduleUpdated(mockSchedule)

      expect(mockSupabase.from().update).not.toHaveBeenCalled()
    })
  })
})
```

## Integration Testing with Real Webhooks

### Real Webhook Event Tests

```typescript
// __tests__/integration/webhook-events.test.ts
import { testStripe, testSupabase } from './setup'
import { handleStripeWebhook } from './webhooks/stripe'

describe('Webhook Integration Tests', () => {
  let testCustomer: any
  let testSubscription: any

  beforeAll(async () => {
    // Create real test data
    testCustomer = await testStripe.customers.create({
      email: 'webhook-integration@test.com',
      metadata: { test_source: 'webhook_integration' }
    })

    testSubscription = await testStripe.subscriptions.create({
      customer: testCustomer.id,
      items: [{ price: getStripePriceId('starter', 'month') }],
      metadata: { test_source: 'webhook_integration' }
    })

    // Create in database
    await testSupabase
      .from('subscriptions')
      .insert({
        user_id: 'webhook_integration_user',
        stripe_subscription_id: testSubscription.id,
        stripe_customer_id: testCustomer.id,
        plan_id: 'starter',
        status: 'active'
      })
  })

  afterAll(async () => {
    // Cleanup
    await testStripe.subscriptions.cancel(testSubscription.id)
    await testStripe.customers.del(testCustomer.id)
  })

  it('should process real invoice.payment_succeeded webhook', async () => {
    // Create and pay invoice
    const invoice = await testStripe.invoices.create({
      customer: testCustomer.id,
      subscription: testSubscription.id
    })

    await testStripe.invoices.finalizeInvoice(invoice.id)
    const paidInvoice = await testStripe.invoices.pay(invoice.id)

    // Create webhook event
    const webhookEvent = {
      id: 'evt_integration_test',
      type: 'invoice.payment_succeeded',
      data: {
        object: paidInvoice
      },
      created: Math.floor(Date.now() / 1000)
    }

    const payload = JSON.stringify(webhookEvent)
    const signature = testStripe.webhooks.generateTestHeaderString({
      payload,
      secret: process.env.STRIPE_WEBHOOK_SECRET!
    })

    // Send webhook request
    const request = new Request('http://localhost:3000/webhooks/stripe', {
      method: 'POST',
      body: payload,
      headers: {
        'stripe-signature': signature,
        'content-type': 'application/json'
      }
    })

    const response = await handleStripeWebhook(request)
    const result = await response.json()

    expect(response.status).toBe(200)
    expect(result.received).toBe(true)

    // Verify database was updated
    const { data: updatedSub } = await testSupabase
      .from('subscriptions')
      .select('*')
      .eq('stripe_subscription_id', testSubscription.id)
      .single()

    expect(updatedSub.status).toBe('active')
    expect(updatedSub.current_period_start).toBeDefined()
    expect(updatedSub.current_period_end).toBeDefined()
  })

  it('should handle webhook idempotency correctly', async () => {
    const webhookEvent = {
      id: 'evt_idempotency_test',
      type: 'customer.subscription.updated',
      data: {
        object: testSubscription
      },
      created: Math.floor(Date.now() / 1000)
    }

    const payload = JSON.stringify(webhookEvent)
    const signature = testStripe.webhooks.generateTestHeaderString({
      payload,
      secret: process.env.STRIPE_WEBHOOK_SECRET!
    })

    const request = new Request('http://localhost:3000/webhooks/stripe', {
      method: 'POST',
      body: payload,
      headers: {
        'stripe-signature': signature,
        'content-type': 'application/json'
      }
    })

    // First request
    const response1 = await POST(request)
    const result1 = await response1.json()

    expect(response1.status).toBe(200)
    expect(result1.received).toBe(true)

    // Second request (duplicate)
    const response2 = await POST(request)
    const result2 = await response2.json()

    expect(response2.status).toBe(200)
    expect(result2.received).toBe(true)
    expect(result2.cached).toBe(true) // Should indicate cached result
  })
})
```

## Testing Webhook Failure Scenarios

### Error Handling Tests

```typescript
// __tests__/webhooks/error-handling.test.ts
import { WebhookEventProcessor } from '@/lib/webhook-processor'

describe('Webhook Error Handling', () => {
  let processor: WebhookEventProcessor

  beforeEach(() => {
    processor = new WebhookEventProcessor()
  })

  it('should handle database connection failures', async () => {
    // Mock database failure
    const mockSupabase = {
      from: jest.fn(() => ({
        update: jest.fn(() => {
          throw new Error('Database connection failed')
        })
      }))
    }

    require('@/lib/supabase-clients').createServerServiceRoleClient.mockReturnValue(mockSupabase)

    const mockEvent = {
      id: 'evt_db_failure',
      type: 'invoice.payment_succeeded',
      data: {
        object: {
          id: 'in_test',
          subscription: 'sub_test',
          amount_paid: 1900,
          period_start: 1640995200,
          period_end: 1643673600
        }
      }
    } as Stripe.Event

    const result = await processor.processEvent(mockEvent, 'req_test')

    expect(result.success).toBe(false)
    expect(result.error).toContain('Database connection failed')
  })

  it('should handle malformed event data', async () => {
    const malformedEvent = {
      id: 'evt_malformed',
      type: 'invoice.payment_succeeded',
      data: {
        object: {
          // Missing required fields
          id: 'in_malformed'
          // No subscription, amount_paid, etc.
        }
      }
    } as Stripe.Event

    const result = await processor.processEvent(malformedEvent, 'req_malformed')

    expect(result.success).toBe(false)
    expect(result.error).toBeDefined()
  })

  it('should handle concurrent processing attempts', async () => {
    const event = {
      id: 'evt_concurrent',
      type: 'customer.subscription.updated',
      data: { object: { id: 'sub_concurrent' } }
    } as Stripe.Event

    // Process same event concurrently
    const promises = [
      processor.processEvent(event, 'req_1'),
      processor.processEvent(event, 'req_2'),
      processor.processEvent(event, 'req_3')
    ]

    const results = await Promise.allSettled(promises)

    // Only one should succeed, others should be handled gracefully
    const successes = results.filter(r => 
      r.status === 'fulfilled' && r.value.success
    ).length

    expect(successes).toBe(1)
  })
})
```

### Webhook Timeout Tests

```typescript
// __tests__/webhooks/timeout-handling.test.ts
describe('Webhook Timeout Handling', () => {
  it('should handle slow database operations', async () => {
    const slowProcessor = async (event: Stripe.Event) => {
      // Simulate slow database operation
      await new Promise(resolve => setTimeout(resolve, 6000)) // 6 seconds
      return { processed: true }
    }

    const timeoutManager = new WebhookTimeoutManager(5000) // 5 second timeout
    
    const result = await timeoutManager.processWithTimeout(
      { id: 'evt_slow' } as Stripe.Event,
      slowProcessor
    )

    expect(result.success).toBe(false)
    expect(result.error).toContain('timeout')
  })

  it('should complete fast operations within timeout', async () => {
    const fastProcessor = async (event: Stripe.Event) => {
      await new Promise(resolve => setTimeout(resolve, 100)) // 100ms
      return { processed: true }
    }

    const timeoutManager = new WebhookTimeoutManager(5000) // 5 second timeout
    
    const result = await timeoutManager.processWithTimeout(
      { id: 'evt_fast' } as Stripe.Event,
      fastProcessor
    )

    expect(result.success).toBe(true)
    expect(result.result).toEqual({ processed: true })
  })
})
```

## Mock Webhook Testing Utilities

### Webhook Event Factory

```typescript
// __tests__/utils/webhook-event-factory.ts
export class WebhookEventFactory {
  /**
   * Create mock invoice.payment_succeeded event
   */
  static createInvoicePaymentSucceeded(overrides: Partial<any> = {}) {
    return {
      id: 'evt_invoice_payment_succeeded',
      type: 'invoice.payment_succeeded',
      created: Math.floor(Date.now() / 1000),
      data: {
        object: {
          id: 'in_test_123',
          subscription: 'sub_test_123',
          customer: 'cus_test_123',
          amount_paid: 1900,
          amount_due: 1900,
          currency: 'usd',
          status: 'paid',
          period_start: Math.floor(Date.now() / 1000) - 86400,
          period_end: Math.floor(Date.now() / 1000) + 86400 * 29,
          lines: {
            data: [{
              description: 'Starter Plan',
              amount: 1900,
              proration: false
            }]
          },
          ...overrides
        }
      }
    } as Stripe.Event
  }

  /**
   * Create mock subscription_schedule.created event
   */
  static createSubscriptionScheduleCreated(overrides: Partial<any> = {}) {
    return {
      id: 'evt_schedule_created',
      type: 'subscription_schedule.created',
      created: Math.floor(Date.now() / 1000),
      data: {
        object: {
          id: 'sub_sched_test_123',
          subscription: 'sub_test_123',
          status: 'active',
          metadata: {},
          phases: [
            {
              start_date: Math.floor(Date.now() / 1000),
              end_date: Math.floor(Date.now() / 1000) + 86400 * 30
            }
          ],
          ...overrides
        }
      }
    } as Stripe.Event
  }

  /**
   * Create mock subscription_schedule.updated event for phase transition
   */
  static createSubscriptionScheduleUpdatedPhase2(overrides: Partial<any> = {}) {
    const phaseStart = Math.floor(Date.now() / 1000)
    
    return {
      id: 'evt_schedule_updated_phase2',
      type: 'subscription_schedule.updated',
      created: Math.floor(Date.now() / 1000),
      data: {
        object: {
          id: 'sub_sched_test_456',
          subscription: 'sub_test_456',
          status: 'active',
          current_phase: {
            start_date: phaseStart // Now in phase 2
          },
          phases: [
            {
              start_date: phaseStart - 86400 * 30, // Phase 1 (past)
              end_date: phaseStart
            },
            {
              start_date: phaseStart // Phase 2 (current)
            }
          ],
          ...overrides
        }
      }
    } as Stripe.Event
  }

  /**
   * Generate valid Stripe signature for test event
   */
  static generateSignature(event: Stripe.Event): string {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    const payload = JSON.stringify(event)
    
    return stripe.webhooks.generateTestHeaderString({
      payload,
      secret: process.env.STRIPE_WEBHOOK_SECRET!
    })
  }
}
```

### Webhook Test Helpers

```typescript
// __tests__/utils/webhook-test-helpers.ts
export async function sendTestWebhook(
  event: Stripe.Event,
  expectedStatus: number = 200
): Promise<any> {
  
  const payload = JSON.stringify(event)
  const signature = WebhookEventFactory.generateSignature(event)

  const request = new Request('http://localhost:3000/api/webhooks/stripe', {
    method: 'POST',
    body: payload,
    headers: {
      'stripe-signature': signature,
      'content-type': 'application/json'
    }
  })

  const response = await POST(request)
  const result = await response.json()

  expect(response.status).toBe(expectedStatus)
  return result
}

export async function verifyDatabaseState(
  subscriptionId: string,
  expectedState: Partial<any>
): Promise<void> {
  
  const { data: subscription, error } = await testSupabase
    .from('subscriptions')
    .select('*')
    .eq('stripe_subscription_id', subscriptionId)
    .single()

  expect(error).toBeNull()
  expect(subscription).toBeDefined()

  // Verify expected state
  Object.keys(expectedState).forEach(key => {
    expect(subscription[key]).toEqual(expectedState[key])
  })
}

export async function simulateWebhookFailure(
  event: Stripe.Event,
  failureType: 'network' | 'database' | 'processing'
): Promise<void> {
  
  // Mock appropriate failure based on type
  switch (failureType) {
    case 'network':
      // Mock network timeout
      jest.spyOn(global, 'fetch').mockRejectedValue(new Error('Network timeout'))
      break
      
    case 'database':
      // Mock database failure
      const mockSupabase = {
        from: jest.fn(() => ({
          update: jest.fn(() => {
            throw new Error('Database connection lost')
          })
        }))
      }
      require('@/lib/supabase-clients').createServerServiceRoleClient.mockReturnValue(mockSupabase)
      break
      
    case 'processing':
      // Mock processing logic failure
      jest.spyOn(console, 'error').mockImplementation(() => {
        throw new Error('Processing logic error')
      })
      break
  }

  // Send webhook and expect failure
  await expect(sendTestWebhook(event, 500)).rejects.toThrow()
}
```

## Performance Testing

### Webhook Load Tests

```typescript
// __tests__/performance/webhook-load.test.ts
describe('Webhook Performance', () => {
  it('should handle high volume of webhooks', async () => {
    const eventCount = 100
    const events = []

    // Create multiple events
    for (let i = 0; i < eventCount; i++) {
      events.push(WebhookEventFactory.createInvoicePaymentSucceeded({
        id: `in_load_test_${i}`,
        subscription: `sub_load_test_${i}`
      }))
    }

    const startTime = Date.now()
    
    // Process events concurrently
    const promises = events.map(event => sendTestWebhook(event))
    const results = await Promise.allSettled(promises)

    const processingTime = Date.now() - startTime
    const successCount = results.filter(r => r.status === 'fulfilled').length

    console.log(`Processed ${successCount}/${eventCount} webhooks in ${processingTime}ms`)

    expect(successCount).toBeGreaterThan(eventCount * 0.95) // 95% success rate
    expect(processingTime).toBeLessThan(30000) // Complete within 30 seconds
  })

  it('should maintain performance under database load', async () => {
    // Create events that will cause database updates
    const updateEvents = []
    
    for (let i = 0; i < 50; i++) {
      updateEvents.push(WebhookEventFactory.createInvoicePaymentSucceeded({
        subscription: 'sub_performance_test' // Same subscription for contention
      }))
    }

    const startTime = Date.now()
    
    // Process sequentially to test database contention
    for (const event of updateEvents) {
      await sendTestWebhook(event)
    }

    const processingTime = Date.now() - startTime
    
    expect(processingTime).toBeLessThan(60000) // Complete within 1 minute
  })
})
```

## Webhook Testing Best Practices

### Test Environment Setup

```typescript
// __tests__/webhooks/test-setup.ts
export async function setupWebhookTestEnvironment() {
  // Ensure test database is clean
  await testSupabase.rpc('cleanup_webhook_test_data')

  // Reset webhook event tracking
  await testSupabase
    .from('webhook_events')
    .delete()
    .like('stripe_event_id', 'evt_test_%')

  // Clear dead letter queue
  await testSupabase
    .from('webhook_dead_letter_queue')
    .delete()
    .like('stripe_event_id', 'evt_test_%')

  console.log('✅ Webhook test environment ready')
}

export async function teardownWebhookTestEnvironment() {
  // Clean up test data
  await testSupabase.rpc('cleanup_webhook_test_data')
  
  console.log('✅ Webhook test environment cleaned up')
}
```

### Test Data Validation

```typescript
// __tests__/utils/webhook-validation.ts
export function validateWebhookEvent(event: any): {
  valid: boolean
  errors: string[]
} {
  const errors: string[] = []

  // Required fields
  if (!event.id) errors.push('Missing event.id')
  if (!event.type) errors.push('Missing event.type')
  if (!event.data) errors.push('Missing event.data')
  if (!event.created) errors.push('Missing event.created')

  // Event ID format
  if (event.id && !event.id.startsWith('evt_')) {
    errors.push('Invalid event ID format')
  }

  // Data object
  if (event.data && !event.data.object) {
    errors.push('Missing event.data.object')
  }

  // Timestamp validation
  if (event.created) {
    const eventAge = Date.now() / 1000 - event.created
    if (eventAge > 86400) { // 24 hours
      errors.push('Event timestamp too old')
    }
    if (eventAge < -300) { // 5 minutes in future
      errors.push('Event timestamp too far in future')
    }
  }

  return {
    valid: errors.length === 0,
    errors
  }
}
```

## Next Steps

In the next module, we'll cover monitoring webhook health and debugging webhook failures in production.

## Key Takeaways

- Test webhook handlers in isolation with unit tests
- Use integration tests with real Stripe events and database
- Test failure scenarios including network and database failures
- Implement comprehensive error handling and graceful degradation
- Test webhook idempotency with duplicate events
- Test performance under high load and database contention
- Use webhook event factories for consistent test data
- Validate webhook event structure and format
- Test timeout scenarios and slow processing
- Set up proper test environment setup and teardown procedures
