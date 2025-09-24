# Unit Testing for Billing Logic

## Overview

This module covers comprehensive unit testing strategies for billing systems, including testing business rules, mocking Stripe operations, and ensuring billing logic correctness. We'll explore patterns from your codebase for reliable billing tests.

## Testing Architecture

Your billing tests should cover multiple layers:

```
Business Logic Tests → API Integration Tests → Webhook Handler Tests → Database Function Tests
```

### Test Categories

1. **Pure Functions**: Plan validation, pricing calculations
2. **API Handlers**: Billing endpoints and request processing  
3. **Webhook Handlers**: Event processing and database updates
4. **Database Operations**: Subscription queries and updates
5. **Integration Points**: Stripe API interactions

## Testing Business Logic

### Plan Configuration Tests

```typescript
// __tests__/lib/plan-config.test.ts
import { 
  getPlanConfig, 
  canUpgradeTo, 
  canDowngradeTo,
  getStripePriceId,
  getPlanTransitionType,
  calculateAnnualSavings
} from '@/lib/plan-config'

describe('Plan Configuration', () => {
  describe('getPlanConfig', () => {
    it('should return plan configuration for valid plans', () => {
      const starter = getPlanConfig('starter')
      expect(starter).toBeDefined()
      expect(starter?.name).toBe('Starter Plan')
      expect(starter?.monthly?.priceCents).toBe(1900)
      expect(starter?.annual?.priceCents).toBe(12900)
    })

    it('should return null for invalid plans', () => {
      const invalid = getPlanConfig('invalid_plan')
      expect(invalid).toBeNull()
    })
  })

  describe('Plan Transitions', () => {
    it('should allow valid upgrades', () => {
      expect(canUpgradeTo('free', 'starter')).toBe(true)
      expect(canUpgradeTo('starter', 'pro')).toBe(true)
      expect(canUpgradeTo('pro', 'scale')).toBe(true)
    })

    it('should reject invalid upgrades', () => {
      expect(canUpgradeTo('pro', 'starter')).toBe(false)
      expect(canUpgradeTo('scale', 'free')).toBe(false)
      expect(canUpgradeTo('starter', 'scale')).toBe(false) // Must go through pro
    })

    it('should allow valid downgrades', () => {
      expect(canDowngradeTo('starter', 'free')).toBe(true)
      expect(canDowngradeTo('pro', 'starter')).toBe(true)
      expect(canDowngradeTo('scale', 'pro')).toBe(true)
    })

    it('should determine transition types correctly', () => {
      expect(getPlanTransitionType('free', 'starter')).toBe('upgrade')
      expect(getPlanTransitionType('starter', 'free')).toBe('downgrade')
      expect(getPlanTransitionType('starter', 'scale')).toBe('invalid')
    })
  })

  describe('Stripe Price Mapping', () => {
    it('should return correct price IDs for monthly billing', () => {
      expect(getStripePriceId('starter', 'month')).toBe('price_1S1EmGHxCxqKRRWFzsKZxGSY')
      expect(getStripePriceId('pro', 'month')).toBe('price_1S1EmZHxCxqKRRWF8fQgO6d2')
    })

    it('should return correct price IDs for annual billing', () => {
      expect(getStripePriceId('starter', 'year')).toBe('price_1S3QQRHxCxqKRRWFm0GiuYxe')
      expect(getStripePriceId('pro', 'year')).toBe('price_1S3QRLHxCxqKRRWF2vbYYoZg')
    })

    it('should return null for unavailable intervals', () => {
      expect(getStripePriceId('free', 'year')).toBeNull()
    })
  })

  describe('Annual Savings Calculation', () => {
    it('should calculate savings correctly', () => {
      const savings = calculateAnnualSavings('starter')
      expect(savings).toBeDefined()
      expect(savings!.monthlyTotal).toBe(228) // $19 × 12
      expect(savings!.annualPrice).toBe(129)
      expect(savings!.savingsAmount).toBe(99)
      expect(savings!.savingsPercent).toBe(43)
    })

    it('should return null for plans without annual pricing', () => {
      const savings = calculateAnnualSavings('free')
      expect(savings).toBeNull()
    })
  })
})
```

### Billing Function Tests

```typescript
// __tests__/lib/billing.test.ts
import { createCheckoutSessionForPlan, getSubscriptionDetails } from '@/lib/billing'
import Stripe from 'stripe'

// Mock Stripe
jest.mock('stripe')
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

describe('Billing Functions', () => {
  beforeEach(() => {
    jest.clearAllMocks()
    ;(Stripe as jest.MockedClass<typeof Stripe>).mockImplementation(() => mockStripe)
  })

  describe('createCheckoutSessionForPlan', () => {
    it('should create checkout session for new customer', async () => {
      // Mock empty customer list (new customer)
      mockStripe.customers.list.mockResolvedValue({ data: [] })
      mockStripe.customers.create.mockResolvedValue({ id: 'cus_new123' })
      mockStripe.checkout.sessions.create.mockResolvedValue({ 
        url: 'https://checkout.stripe.com/pay/test123' 
      })

      // Mock getSubscriptionDetails to return null (no existing subscription)
      jest.mocked(getSubscriptionDetails).mockResolvedValue(null)

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
      expect(mockStripe.checkout.sessions.create).toHaveBeenCalledWith({
        customer: 'cus_new123',
        payment_method_types: ['card'],
        line_items: [{
          price: 'price_1S1EmGHxCxqKRRWFzsKZxGSY', // Starter monthly price
          quantity: 1,
        }],
        mode: 'subscription',
        success_url: 'http://localhost:3000/success',
        cancel_url: 'http://localhost:3000/cancel',
        metadata: {
          userId: 'user123',
          planId: 'starter',
          billingInterval: 'month'
        },
        allow_promotion_codes: true,
        billing_address_collection: 'auto',
        tax_id_collection: { enabled: true }
      })
    })

    it('should use existing customer when available', async () => {
      // Mock existing customer
      mockStripe.customers.list.mockResolvedValue({ 
        data: [{ id: 'cus_existing123' }] 
      })
      mockStripe.checkout.sessions.create.mockResolvedValue({ 
        url: 'https://checkout.stripe.com/pay/test456' 
      })

      jest.mocked(getSubscriptionDetails).mockResolvedValue(null)

      const result = await createCheckoutSessionForPlan(
        'user123',
        'test@example.com',
        'pro',
        'http://localhost:3000/success',
        'http://localhost:3000/cancel',
        'year'
      )

      expect(result.url).toBe('https://checkout.stripe.com/pay/test456')
      expect(mockStripe.customers.create).not.toHaveBeenCalled()
      expect(mockStripe.checkout.sessions.create).toHaveBeenCalledWith(
        expect.objectContaining({
          customer: 'cus_existing123',
          line_items: [{
            price: 'price_1S3QRLHxCxqKRRWF2vbYYoZg', // Pro annual price
            quantity: 1,
          }],
          metadata: expect.objectContaining({
            billingInterval: 'year'
          })
        })
      )
    })

    it('should handle plan not found error', async () => {
      await expect(
        createCheckoutSessionForPlan(
          'user123',
          'test@example.com',
          'invalid_plan',
          'http://localhost:3000/success',
          'http://localhost:3000/cancel'
        )
      ).rejects.toThrow('Plan not found')
    })
  })
})
```

## Testing API Endpoints

### Billing API Tests

```typescript
// __tests__/app/api/billing/upgrade/route.test.ts
import { POST } from '@/app/api/billing/upgrade/route'
import { Request } from 'next/server'
import { createMocks } from 'node-mocks-http'

// Mock dependencies
jest.mock('@/lib/supabase-clients')
jest.mock('stripe')

describe('/api/billing/upgrade', () => {
  let mockSupabase: any

  beforeEach(() => {
    mockSupabase = {
      auth: {
        getUser: jest.fn()
      },
      from: jest.fn(() => ({
        select: jest.fn(() => ({
          eq: jest.fn(() => ({
            order: jest.fn(() => ({
              limit: jest.fn(() => ({
                single: jest.fn()
              }))
            }))
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

    require('@/lib/supabase-clients').createServerUserClient.mockReturnValue(mockSupabase)
  })

  it('should require authentication', async () => {
    mockSupabase.auth.getUser.mockResolvedValue({ data: { user: null }, error: null })

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
    mockSupabase.auth.getUser.mockResolvedValue({ 
      data: { user: { id: 'user123', email: 'test@example.com' } }, 
      error: null 
    })

    const request = new Request('http://localhost:3000/api/billing/upgrade', {
      method: 'POST',
      body: JSON.stringify({}) // Missing newPlanId
    })

    const response = await POST(request)
    const data = await response.json()

    expect(response.status).toBe(400)
    expect(data.error).toBe('Missing newPlanId')
  })

  it('should handle successful upgrade', async () => {
    // Mock authenticated user
    mockSupabase.auth.getUser.mockResolvedValue({ 
      data: { user: { id: 'user123', email: 'test@example.com' } }, 
      error: null 
    })

    // Mock subscription retrieval
    mockSupabase.from().select().eq().order().limit().single.mockResolvedValue({
      data: {
        id: 'sub_123',
        stripe_subscription_id: 'sub_stripe_123',
        plan_id: 'starter',
        stripe_price_id: 'price_starter_monthly'
      },
      error: null
    })

    // Mock Stripe operations
    const mockStripeInstance = {
      subscriptions: {
        retrieve: jest.fn().mockResolvedValue({
          items: { data: [{ id: 'si_123' }] }
        }),
        update: jest.fn().mockResolvedValue({
          status: 'active',
          current_period_start: 1640995200,
          current_period_end: 1643673600
        })
      }
    }

    require('stripe').mockImplementation(() => mockStripeInstance)

    // Mock database update
    mockSupabase.from().update().eq().select().single.mockResolvedValue({
      data: { id: 'sub_123', plan_id: 'pro' },
      error: null
    })

    const request = new Request('http://localhost:3000/api/billing/upgrade', {
      method: 'POST',
      body: JSON.stringify({ 
        newPlanId: 'pro',
        billingInterval: 'month'
      })
    })

    const response = await POST(request)
    const data = await response.json()

    expect(response.status).toBe(200)
    expect(data.success).toBe(true)
    expect(data.subscription.plan_id).toBe('pro')
  })
})
```

## Testing Webhook Handlers

### Webhook Handler Tests

```typescript
// __tests__/api/webhooks/stripe-webhook.test.ts
import { POST } from '@/app/api/webhooks/stripe/route'
import { Request } from 'next/server'
import Stripe from 'stripe'

// Mock Stripe webhook verification
jest.mock('stripe')

describe('Stripe Webhook Handler', () => {
  let mockStripe: any

  beforeEach(() => {
    mockStripe = {
      webhooks: {
        constructEvent: jest.fn()
      }
    }
    ;(Stripe as jest.MockedClass<typeof Stripe>).mockImplementation(() => mockStripe)
  })

  it('should verify webhook signature', async () => {
    const mockEvent = {
      id: 'evt_test_webhook',
      type: 'customer.subscription.updated',
      data: {
        object: {
          id: 'sub_test_123',
          status: 'active'
        }
      }
    }

    mockStripe.webhooks.constructEvent.mockReturnValue(mockEvent)

    const payload = JSON.stringify(mockEvent)
    const request = new Request('http://localhost:3000/api/webhooks/stripe', {
      method: 'POST',
      body: payload,
      headers: {
        'stripe-signature': 'valid_signature',
        'content-type': 'application/json'
      }
    })

    const response = await POST(request)
    const result = await response.json()

    expect(response.status).toBe(200)
    expect(result.received).toBe(true)
    expect(mockStripe.webhooks.constructEvent).toHaveBeenCalledWith(
      payload,
      'valid_signature',
      process.env.STRIPE_WEBHOOK_SECRET
    )
  })

  it('should reject invalid signatures', async () => {
    mockStripe.webhooks.constructEvent.mockImplementation(() => {
      throw new Error('Invalid signature')
    })

    const request = new Request('http://localhost:3000/api/webhooks/stripe', {
      method: 'POST',
      body: JSON.stringify({}),
      headers: {
        'stripe-signature': 'invalid_signature'
      }
    })

    const response = await POST(request)
    const result = await response.json()

    expect(response.status).toBe(400)
    expect(result.error).toBe('Invalid signature')
  })

  it('should handle missing signature header', async () => {
    const request = new Request('http://localhost:3000/api/webhooks/stripe', {
      method: 'POST',
      body: JSON.stringify({})
      // No stripe-signature header
    })

    const response = await POST(request)
    const result = await response.json()

    expect(response.status).toBe(400)
    expect(result.error).toBe('Missing stripe-signature header')
  })
})
```

### Individual Webhook Handler Tests

```typescript
// __tests__/lib/webhook-handlers.test.ts
import { 
  handleInvoicePaymentPaid,
  handleSubscriptionScheduleCreated,
  handleSubscriptionScheduleUpdated
} from '@/app/api/webhooks/stripe/handlers'

// Mock Supabase
jest.mock('@/lib/supabase-clients')

describe('Webhook Handlers', () => {
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
        })),
        select: jest.fn(() => ({
          eq: jest.fn(() => ({
            single: jest.fn()
          }))
        }))
      }))
    }

    require('@/lib/supabase-clients').createServerServiceRoleClient.mockReturnValue(mockSupabase)
  })

  describe('handleInvoicePaymentPaid', () => {
    it('should update subscription status on successful payment', async () => {
      const mockInvoice = {
        id: 'in_test_123',
        subscription: 'sub_test_123',
        amount_paid: 1900,
        currency: 'usd',
        status: 'paid',
        period_start: 1640995200,
        period_end: 1643673600
      }

      mockSupabase.from().update().eq().select().single.mockResolvedValue({
        data: { id: 'sub_db_123', status: 'active' },
        error: null
      })

      const result = await handleInvoicePaymentPaid(mockInvoice)

      expect(result).toBeDefined()
      expect(mockSupabase.from).toHaveBeenCalledWith('subscriptions')
      expect(mockSupabase.from().update).toHaveBeenCalledWith({
        status: 'active',
        current_period_start: expect.any(String),
        current_period_end: expect.any(String),
        updated_at: expect.any(String)
      })
    })

    it('should handle missing subscription ID', async () => {
      const mockInvoice = {
        id: 'in_test_123',
        // No subscription field
        amount_paid: 1900
      }

      const result = await handleInvoicePaymentPaid(mockInvoice)

      expect(result).toBeUndefined()
      expect(mockSupabase.from).not.toHaveBeenCalled()
    })
  })

  describe('handleSubscriptionScheduleCreated', () => {
    it('should set cancel_at_period_end for regular downgrades', async () => {
      const mockSchedule = {
        id: 'sub_sched_123',
        subscription: 'sub_test_123',
        metadata: {} // No interval switch metadata
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

    it('should skip cancel_at_period_end for interval switches', async () => {
      const mockSchedule = {
        id: 'sub_sched_123',
        subscription: 'sub_test_123',
        metadata: {
          ffm_interval_switch: '1'
        }
      }

      mockSupabase.from().select().eq().single.mockResolvedValue({
        data: { 
          id: 'sub_db_123', 
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
})
```

## Testing Database Functions

### RPC Function Tests

```typescript
// __tests__/database/subscription-functions.test.ts
import { createServerServiceRoleClient } from '@/lib/supabase-clients'

describe('Database Functions', () => {
  let supabase: any

  beforeEach(() => {
    supabase = createServerServiceRoleClient()
  })

  describe('get_user_active_subscription', () => {
    it('should return active subscription for user', async () => {
      const { data, error } = await supabase
        .rpc('get_user_active_subscription', { 
          user_uuid: 'test-user-id' 
        })

      expect(error).toBeNull()
      expect(data).toBeDefined()
      
      if (data && data.length > 0) {
        expect(data[0]).toHaveProperty('id')
        expect(data[0]).toHaveProperty('plan_type')
        expect(data[0]).toHaveProperty('status')
        expect(['active', 'trialing', 'past_due']).toContain(data[0].status)
      }
    })

    it('should return empty array for user without subscription', async () => {
      const { data, error } = await supabase
        .rpc('get_user_active_subscription', { 
          user_uuid: 'nonexistent-user' 
        })

      expect(error).toBeNull()
      expect(data).toEqual([])
    })
  })

  describe('get_usage_summary', () => {
    it('should aggregate usage by feature', async () => {
      const periodStart = new Date('2024-01-01').toISOString()
      const periodEnd = new Date('2024-02-01').toISOString()

      const { data, error } = await supabase
        .rpc('get_usage_summary', {
          user_uuid: 'test-user-id',
          period_start: periodStart,
          period_end: periodEnd
        })

      expect(error).toBeNull()
      expect(Array.isArray(data)).toBe(true)
      
      if (data && data.length > 0) {
        expect(data[0]).toHaveProperty('feature_name')
        expect(data[0]).toHaveProperty('total_usage')
        expect(data[0]).toHaveProperty('record_count')
      }
    })
  })
})
```

## Mock Utilities

### Stripe Mock Factory

```typescript
// __tests__/utils/stripe-mocks.ts
export function createStripeMock() {
  return {
    customers: {
      list: jest.fn(),
      create: jest.fn(),
      retrieve: jest.fn(),
      update: jest.fn(),
      del: jest.fn()
    },
    subscriptions: {
      create: jest.fn(),
      retrieve: jest.fn(),
      update: jest.fn(),
      cancel: jest.fn(),
      list: jest.fn()
    },
    subscriptionSchedules: {
      create: jest.fn(),
      retrieve: jest.fn(),
      update: jest.fn(),
      cancel: jest.fn(),
      release: jest.fn(),
      list: jest.fn()
    },
    checkout: {
      sessions: {
        create: jest.fn(),
        retrieve: jest.fn()
      }
    },
    invoices: {
      retrieveUpcoming: jest.fn(),
      list: jest.fn()
    },
    webhooks: {
      constructEvent: jest.fn(),
      generateTestHeaderString: jest.fn()
    }
  }
}

export function mockSuccessfulCheckoutSession(sessionId: string = 'cs_test_123') {
  return {
    id: sessionId,
    url: `https://checkout.stripe.com/pay/${sessionId}`,
    customer: 'cus_test_123',
    subscription: 'sub_test_123',
    payment_status: 'paid',
    metadata: {
      userId: 'user_test_123',
      planId: 'starter'
    }
  }
}

export function mockActiveSubscription(
  subscriptionId: string = 'sub_test_123',
  planId: string = 'starter'
) {
  return {
    id: subscriptionId,
    customer: 'cus_test_123',
    status: 'active',
    current_period_start: Math.floor(Date.now() / 1000) - 86400, // 1 day ago
    current_period_end: Math.floor(Date.now() / 1000) + 86400 * 29, // 29 days from now
    cancel_at_period_end: false,
    items: {
      data: [{
        id: 'si_test_123',
        price: {
          id: getStripePriceId(planId, 'month')
        }
      }]
    },
    metadata: {
      planId: planId
    }
  }
}
```

### Test Data Factory

```typescript
// __tests__/utils/test-data-factory.ts
export class TestDataFactory {
  static createUser(overrides: Partial<any> = {}) {
    return {
      id: 'user_test_123',
      email: 'test@example.com',
      first_name: 'Test',
      last_name: 'User',
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      ...overrides
    }
  }

  static createSubscription(overrides: Partial<any> = {}) {
    return {
      id: 'sub_test_123',
      user_id: 'user_test_123',
      stripe_subscription_id: 'sub_stripe_123',
      stripe_customer_id: 'cus_test_123',
      stripe_price_id: 'price_1S1EmGHxCxqKRRWFzsKZxGSY',
      plan_id: 'starter',
      status: 'active',
      current_period_start: new Date().toISOString(),
      current_period_end: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
      cancel_at_period_end: false,
      metadata: {},
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      ...overrides
    }
  }

  static createUsageRecord(overrides: Partial<any> = {}) {
    return {
      id: 'usage_test_123',
      user_id: 'user_test_123',
      feature_name: 'compute_minutes',
      usage_amount: 100,
      usage_date: new Date().toISOString().split('T')[0],
      billing_period_start: new Date().toISOString(),
      billing_period_end: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
      metadata: {},
      created_at: new Date().toISOString(),
      ...overrides
    }
  }

  static createInvoice(overrides: Partial<any> = {}) {
    return {
      id: 'in_test_123',
      customer: 'cus_test_123',
      subscription: 'sub_test_123',
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
}
```

## Test Configuration

### Jest Configuration for Billing Tests

```javascript
// jest.config.js
module.exports = {
  testEnvironment: 'node',
  setupFilesAfterEnv: ['<rootDir>/jest.setup.js'],
  testMatch: [
    '**/__tests__/**/*.test.{js,ts}',
    '**/?(*.)+(spec|test).{js,ts}'
  ],
  moduleNameMapping: {
    '^@/(.*)$': '<rootDir>/$1'
  },
  collectCoverageFrom: [
    'lib/**/*.{js,ts}',
    'app/api/**/*.{js,ts}',
    '!**/*.d.ts',
    '!**/node_modules/**'
  ],
  coverageThreshold: {
    global: {
      branches: 80,
      functions: 80,
      lines: 80,
      statements: 80
    },
    // Higher thresholds for critical billing code
    './lib/billing.ts': {
      branches: 90,
      functions: 90,
      lines: 90,
      statements: 90
    },
    './app/api/billing/**/*.ts': {
      branches: 85,
      functions: 85,
      lines: 85,
      statements: 85
    }
  }
}
```

### Test Setup File

```typescript
// jest.setup.js
import { jest } from '@jest/globals'

// Mock environment variables
process.env.STRIPE_SECRET_KEY = 'sk_test_mock_key'
process.env.STRIPE_WEBHOOK_SECRET = 'whsec_mock_secret'
process.env.SUPABASE_URL = 'https://mock.supabase.co'
process.env.SUPABASE_SERVICE_ROLE_KEY = 'mock_service_role_key'
process.env.APP_URL = 'http://localhost:3000'

// Mock console methods to reduce test noise
global.console = {
  ...console,
  log: jest.fn(),
  warn: jest.fn(),
  error: jest.fn()
}

// Mock fetch for API tests
global.fetch = jest.fn()

// Setup test database connection
beforeAll(async () => {
  // Initialize test database if needed
})

afterAll(async () => {
  // Cleanup test database if needed
})

beforeEach(() => {
  // Clear all mocks before each test
  jest.clearAllMocks()
})
```

## Testing Best Practices

### Test Organization

```typescript
// Organize tests by feature area
describe('Billing System', () => {
  describe('Plan Management', () => {
    describe('Plan Validation', () => {
      // Plan validation tests
    })
    
    describe('Plan Transitions', () => {
      // Upgrade/downgrade tests
    })
  })

  describe('Subscription Management', () => {
    describe('Subscription Creation', () => {
      // Checkout and subscription tests
    })
    
    describe('Subscription Updates', () => {
      // Plan change tests
    })
  })

  describe('Usage Tracking', () => {
    describe('Usage Recording', () => {
      // Usage recording tests
    })
    
    describe('Limit Enforcement', () => {
      // Usage limit tests
    })
  })
})
```

### Test Data Management

```typescript
// __tests__/utils/test-database.ts
export async function seedTestData() {
  const supabase = createServerServiceRoleClient()
  
  // Create test users
  const testUsers = [
    TestDataFactory.createUser({ email: 'free@test.com' }),
    TestDataFactory.createUser({ email: 'starter@test.com' }),
    TestDataFactory.createUser({ email: 'pro@test.com' })
  ]

  for (const user of testUsers) {
    await supabase.from('users').insert(user)
  }

  // Create test subscriptions
  const testSubscriptions = [
    TestDataFactory.createSubscription({ 
      user_id: testUsers[1].id, 
      plan_id: 'starter' 
    }),
    TestDataFactory.createSubscription({ 
      user_id: testUsers[2].id, 
      plan_id: 'pro' 
    })
  ]

  for (const subscription of testSubscriptions) {
    await supabase.from('subscriptions').insert(subscription)
  }
}

export async function cleanupTestData() {
  const supabase = createServerServiceRoleClient()
  
  // Clean up in reverse dependency order
  await supabase.from('usage_records').delete().like('user_id', 'user_test_%')
  await supabase.from('subscriptions').delete().like('user_id', 'user_test_%')
  await supabase.from('users').delete().like('id', 'user_test_%')
}
```

## Next Steps

In the next module, we'll cover integration testing patterns for testing with real Stripe test data and database interactions.

## Key Takeaways

- Test business logic functions thoroughly with unit tests
- Mock Stripe API calls for predictable test results
- Test webhook handlers with realistic event payloads
- Use test data factories for consistent test data creation
- Implement proper test setup and teardown procedures
- Test error scenarios and edge cases comprehensively
- Use appropriate coverage thresholds for critical billing code
- Organize tests by feature area for maintainability
- Mock external dependencies to isolate units under test
- Test database functions with real database interactions
