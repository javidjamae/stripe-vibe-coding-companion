# E2E Testing Patterns with Cypress and Stripe

## Overview

This module covers end-to-end testing patterns for Stripe integrations using Cypress, based on the comprehensive test suite found in your codebase. We'll explore test isolation, data seeding, webhook simulation, and best practices for reliable billing tests.

## E2E Testing Architecture

Your codebase implements a sophisticated E2E testing architecture:

```
Cypress Tests → Seed Helpers → Test Database → Stripe Test Mode → Webhook Simulation
```

### Key Components

1. **Seed Helpers**: Create deterministic test data
2. **Authentication Bridge**: Handle user authentication in tests
3. **API Intercepts**: Monitor and control API calls
4. **Webhook Simulation**: Test webhook handlers without Stripe
5. **Database Assertions**: Verify data consistency

## Test Data Seeding Patterns

### Core Seed Helpers

```typescript
// cypress/support/seed-helpers.ts
export async function seedStarterUserWithStripeSubscription(email: string) {
  console.log(`🌱 Seeding Starter user with Stripe subscription: ${email}`)
  
  try {
    // Create user in Supabase Auth
    const { data: authUser, error: authError } = await supabaseAdmin.auth.admin.createUser({
      email: email,
      password: 'TestPassword123!',
      email_confirm: true
    })

    if (authError) {
      throw new Error(`Auth user creation failed: ${authError.message}`)
    }

    const userId = authUser.user.id

    // Create user profile
    const { error: profileError } = await supabaseAdmin
      .from('users')
      .insert({
        id: userId,
        email: email,
        first_name: 'Test',
        last_name: 'User',
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      })

    if (profileError) {
      throw new Error(`Profile creation failed: ${profileError.message}`)
    }

    // Create Stripe customer
    const customer = await stripe.customers.create({
      email: email,
      name: 'Test User',
      metadata: {
        userId: userId,
        test_source: 'cypress'
      }
    })

    // Create Stripe subscription
    const subscription = await stripe.subscriptions.create({
      customer: customer.id,
      items: [{
        price: 'price_1S1EmGHxCxqKRRWFzsKZxGSY' // Starter monthly price
      }],
      metadata: {
        userId: userId,
        planId: 'starter',
        test_source: 'cypress'
      }
    })

    // Create subscription in database
    const { error: subError } = await supabaseAdmin
      .from('subscriptions')
      .insert({
        user_id: userId,
        stripe_subscription_id: subscription.id,
        stripe_customer_id: customer.id,
        stripe_price_id: 'price_1S1EmGHxCxqKRRWFzsKZxGSY',
        plan_id: 'starter',
        status: 'active',
        current_period_start: new Date(subscription.current_period_start * 1000).toISOString(),
        current_period_end: new Date(subscription.current_period_end * 1000).toISOString(),
        cancel_at_period_end: false,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      })

    if (subError) {
      throw new Error(`Subscription creation failed: ${subError.message}`)
    }

    console.log(`✅ Successfully seeded Starter user: ${userId}`)
    return {
      ok: true,
      userId: userId,
      customerId: customer.id,
      subscriptionId: subscription.id
    }

  } catch (error) {
    console.error('❌ Seed operation failed:', error)
    return {
      ok: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    }
  }
}
```

### Specialized Seed Functions

```typescript
// Seed user with scheduled downgrade
export async function seedStarterUserWithScheduledDowngrade(email: string) {
  const result = await seedStarterUserWithStripeSubscription(email)
  
  if (!result.ok) {
    return result
  }

  try {
    // Update Stripe subscription to have cancel_at_period_end = true
    await stripe.subscriptions.update(result.subscriptionId, {
      cancel_at_period_end: true
    })

    // Update database with scheduled change metadata
    const scheduledChange = {
      planId: 'free',
      interval: 'month',
      priceId: 'price_1S1EldHxCxqKRRWFkYhT6myo',
      effectiveAt: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString() // 30 days from now
    }

    await supabaseAdmin
      .from('subscriptions')
      .update({
        cancel_at_period_end: true,
        metadata: {
          scheduled_change: scheduledChange
        }
      })
      .eq('stripe_subscription_id', result.subscriptionId)

    console.log(`✅ Added scheduled downgrade for user: ${result.userId}`)
    return result

  } catch (error) {
    console.error('❌ Failed to add scheduled downgrade:', error)
    return {
      ok: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    }
  }
}

// Seed Pro Annual user for complex upgrade testing
export async function seedProAnnualUserWithStripeSubscription(email: string) {
  // Similar to seedStarterUser but with Pro Annual price
  // Implementation follows same pattern with different price ID
  const customer = await stripe.customers.create({
    email: email,
    name: 'Test User',
    metadata: {
      userId: userId,
      test_source: 'cypress'
    }
  })

  const subscription = await stripe.subscriptions.create({
    customer: customer.id,
    items: [{
      price: 'price_1S3QRLHxCxqKRRWF2vbYYoZg' // Pro annual price
    }],
    metadata: {
      userId: userId,
      planId: 'pro',
      billingInterval: 'year',
      test_source: 'cypress'
    }
  })

  // ... rest of implementation
}
```

## Authentication in Tests

### Auth Bridge Pattern

```typescript
// app/test/auth-bridge/page.tsx
'use client'

import { useEffect, useState } from 'react'
import { createClientComponentClient } from '@supabase/auth-helpers-nextjs'

export default function AuthBridge() {
  const [status, setStatus] = useState<'checking' | 'ok' | 'error'>('checking')
  const supabase = createClientComponentClient()

  useEffect(() => {
    const checkAuth = async () => {
      try {
        const { data: { user }, error } = await supabase.auth.getUser()
        
        if (error) {
          console.error('Auth bridge error:', error)
          setStatus('error')
          return
        }

        if (user) {
          setStatus('ok')
        } else {
          setStatus('error')
        }
      } catch (error) {
        console.error('Auth bridge exception:', error)
        setStatus('error')
      }
    }

    checkAuth()
  }, [supabase])

  return (
    <div className="p-4">
      <div data-testid="auth-bridge-status">{status}</div>
      {status === 'ok' && <div data-testid="auth-bridge-ready">Ready</div>}
    </div>
  )
}
```

### Test Login API

```typescript
// app/api/test/login/route.ts
export async function POST(request: Request) {
  try {
    const { email, password } = await request.json()
    
    if (!email || !password) {
      return new Response(
      JSON.stringify({ error: 'Missing email or password' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    // Only allow test login in development/test environments
    if (process.env.NODE_ENV === 'production') {
      return new Response(
      JSON.stringify({ error: 'Test login not available in production' ),
      { status: 403 })
    }

    const supabase = createServerServiceRoleClient()
    
    // Sign in the user
    const { data, error } = await supabase.auth.signInWithPassword({
      email,
      password
    })

    if (error) {
      console.error('Test login error:', error)
      return new Response(
      JSON.stringify({ error: 'Login failed' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    return new Response(
      JSON.stringify({ 
      ok: true,
      user: data.user,
      session: data.session
    })

  } catch (error) {
    console.error('Test login exception:', error)
    return new Response(
      JSON.stringify({ error: 'Internal server error' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Cypress Test Patterns

### Test Structure and Isolation

```typescript
// cypress/e2e/billing/upgrade-flow.cy.ts
describe('Upgrade Flow', () => {
  const email = `upgrade-test-${Date.now()}@example.com`

  beforeEach(() => {
    // Clear any existing session
    cy.clearCookies()
    cy.clearLocalStorage()
  })

  describe('Starter to Pro Upgrade', () => {
    beforeEach(() => {
      // Seed a Starter user with active subscription
      cy.task('seedStarterUserWithStripeSubscription', { email }).then((result: any) => {
        expect(result.ok).to.be.true
        expect(result.subscriptionId).to.exist
        expect(result.userId).to.exist

        cy.log('Created Starter user with ID:', result.userId)
      }).then(() => {
        // Authenticate the seeded user
        cy.log('About to login with email:', email)

        return cy.request({
          method: 'POST',
          url: '/api/test/login',
          body: {
            email,
            password: 'TestPassword123!'
          }
        })
      }).then((response) => {
        cy.log('Login response status:', response.status)
        expect(response.status).to.eq(200)
        expect(response.body.ok).to.be.true

        cy.log('Login successful for email:', email)

        // Verify authentication bridge is working
        cy.visit('/test/auth-bridge')
        cy.get('[data-testid="auth-bridge-status"]').should('contain', 'ok')
        cy.wait(1000) // Give auth bridge time to complete
      })
    })

    it('should upgrade from Starter to Pro with proration', () => {
      cy.visit('/billing')

      // Wait for page to load and data to be visible
      cy.get('[data-testid="current-plan-section"]').should('be.visible')
      cy.wait(1500)

      // Verify we're on Starter plan
      cy.get('[data-testid="current-plan-name"]').should('contain', 'Starter')
      cy.get('[data-testid="starter-current-plan-badge"]').should('be.visible')

      // Click "Select Plan" button on Pro plan
      cy.get('[data-testid="pro-action-button"]').click()

      // Verify the upgrade confirmation modal appears
      cy.get('[data-testid="upgrade-confirmation-modal"]').should('be.visible')
      cy.get('[data-testid="upgrade-modal-title"]').should('contain', 'Upgrade to Pro')

      // Verify proration message is shown
      cy.get('[data-testid="upgrade-modal-body"]').should('contain', 'prorated amount')
      cy.get('[data-testid="upgrade-modal-body"]').should('contain', 'features right away')

      // Intercept API call to assert success
      cy.intercept('POST', '/api/billing/upgrade').as('upgradeRequest')

      // Click "Confirm Upgrade" button
      cy.get('[data-testid="confirm-upgrade-button"]').click()

      // Wait for the API call to complete and assert status
      cy.wait('@upgradeRequest', { timeout: 15000 }).then((interception) => {
        cy.log('Upgrade API response status:', interception.response?.statusCode)
        expect(interception.response?.statusCode).to.eq(200)
      })

      // Verify modal closes
      cy.get('[data-testid="upgrade-confirmation-modal"]').should('not.exist')

      // Verify success toast
      cy.get('[data-testid="upgrade-success-toast"]').should('be.visible')

      // Refresh the page to ensure UI reflects the change from DB
      cy.reload()

      // Verify we're now on Pro plan
      cy.get('[data-testid="current-plan-name"]').should('contain', 'Pro')
      cy.get('[data-testid="pro-current-plan-badge"]').should('be.visible')
    })
  })
})
```

### API Intercept Patterns

```typescript
// Intercept with test mode header
cy.intercept('POST', '/api/billing/downgrade-to-free', (req) => {
  req.headers['x-test-mode'] = 'cypress'
  req.continue()
}).as('downgradeApi')

// Intercept with response modification
cy.intercept('POST', '/api/billing/upgrade', (req) => {
  // Allow real request but add test context
  req.headers['x-test-source'] = 'cypress'
  req.reply() // Let the real request continue
}).as('upgradeRequest')

// Intercept for error testing
cy.intercept('POST', '/api/billing/upgrade', { 
  statusCode: 500, 
  body: { error: 'Upgrade failed' } 
}).as('upgradeRequest')
```

## Webhook Testing Patterns

### Webhook Simulation

```typescript
// cypress/tasks/webhook-simulation.ts
export async function simulateSubscriptionScheduleUpdated(email: string) {
  console.log(`🔄 Simulating subscription_schedule.updated for ${email}`)
  
  try {
    // Get user's subscription
    const { data: subscription, error } = await supabaseAdmin
      .from('subscriptions')
      .select('stripe_subscription_id, metadata')
      .eq('user_id', (await getUserByEmail(email)).id)
      .single()

    if (error || !subscription) {
      throw new Error('Subscription not found')
    }

    // Create mock schedule payload
    const mockSchedule = {
      id: 'sub_sched_test_123',
      subscription: subscription.stripe_subscription_id,
      status: 'active',
      current_phase: {
        start_date: Math.floor(Date.now() / 1000) + 86400 // Tomorrow
      },
      phases: [
        {
          start_date: Math.floor(Date.now() / 1000),
          end_date: Math.floor(Date.now() / 1000) + 86400
        },
        {
          start_date: Math.floor(Date.now() / 1000) + 86400
        }
      ]
    }

    // Directly call the webhook handler (bypasses signature verification)
    const { handleSubscriptionScheduleUpdated } = await import(
      '../../../app/api/webhooks/stripe/handlers'
    )
    
    await handleSubscriptionScheduleUpdated(mockSchedule)
    
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

### Database State Verification

```typescript
// cypress/tasks/database-helpers.ts
export async function getStripeCancelFlagForEmail(email: string) {
  try {
    const user = await getUserByEmail(email)
    
    const { data: subscription, error } = await supabaseAdmin
      .from('subscriptions')
      .select('stripe_subscription_id')
      .eq('user_id', user.id)
      .single()

    if (error || !subscription?.stripe_subscription_id) {
      return { ok: false, error: 'Subscription not found' }
    }

    // Get from Stripe
    const stripeSubscription = await stripe.subscriptions.retrieve(
      subscription.stripe_subscription_id
    )

    return {
      ok: true,
      cancel_at_period_end: stripeSubscription.cancel_at_period_end
    }

  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    }
  }
}

export async function getDbCancelFlagForEmail(email: string) {
  try {
    const user = await getUserByEmail(email)
    
    const { data: subscription, error } = await supabaseAdmin
      .from('subscriptions')
      .select('cancel_at_period_end')
      .eq('user_id', user.id)
      .single()

    if (error) {
      return { ok: false, error: 'Subscription not found' }
    }

    return {
      ok: true,
      cancel_at_period_end: subscription.cancel_at_period_end
    }

  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    }
  }
}
```

## Test Configuration

### Cypress Configuration

```typescript
// cypress.config.ts
import { defineConfig } from 'cypress'

export default defineConfig({
  e2e: {
    baseUrl: 'http://localhost:3000',
    supportFile: 'cypress/support/e2e.ts',
    specPattern: 'cypress/e2e/**/*.cy.{js,jsx,ts,tsx}',
    video: false,
    screenshotOnRunFailure: true,
    
    setupNodeEvents(on, config) {
      // Import task handlers
      on('task', {
        // Seed helpers
        seedStarterUser: require('./cypress/tasks/seed-helpers').seedStarterUser,
        seedStarterUserWithStripeSubscription: require('./cypress/tasks/seed-helpers').seedStarterUserWithStripeSubscription,
        seedStarterUserWithScheduledDowngrade: require('./cypress/tasks/seed-helpers').seedStarterUserWithScheduledDowngrade,
        seedProAnnualUserWithStripeSubscription: require('./cypress/tasks/seed-helpers').seedProAnnualUserWithStripeSubscription,
        
        // Database helpers
        getStripeCancelFlagForEmail: require('./cypress/tasks/database-helpers').getStripeCancelFlagForEmail,
        getDbCancelFlagForEmail: require('./cypress/tasks/database-helpers').getDbCancelFlagForEmail,
        
        // Webhook simulation
        simulateSubscriptionScheduleUpdated: require('./cypress/tasks/webhook-simulation').simulateSubscriptionScheduleUpdated,
        
        // Cleanup helpers
        cleanupTestData: require('./cypress/tasks/cleanup').cleanupTestData,
      })

      return config
    },
    
    env: {
      // Test environment variables
      SUPABASE_URL: process.env.SUPABASE_URL,
      SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
      STRIPE_SECRET_KEY: process.env.STRIPE_SECRET_KEY,
    }
  }
})
```

### Test Environment Setup

```typescript
// cypress/support/e2e.ts
import './commands'

// Global test configuration
Cypress.on('uncaught:exception', (err, runnable) => {
  // Ignore certain errors that don't affect test functionality
  if (err.message.includes('ResizeObserver loop limit exceeded')) {
    return false
  }
  return true
})

// Custom commands
declare global {
  namespace Cypress {
    interface Chainable {
      login(email: string): Chainable<void>
      seedUser(options: { email: string, plan?: string }): Chainable<void>
    }
  }
}
```

### Custom Commands

```typescript
// cypress/support/commands.ts
Cypress.Commands.add('login', (email: string) => {
  cy.request({
    method: 'POST',
    url: '/api/test/login',
    body: {
      email,
      password: 'TestPassword123!'
    }
  }).should('have.property', 'status', 200)

  // Visit auth bridge to establish session
  cy.visit('/test/auth-bridge')
  cy.get('[data-testid="auth-bridge-status"]').should('contain', 'ok')
})

Cypress.Commands.add('seedUser', (options: { email: string, plan?: string }) => {
  const taskName = options.plan === 'pro' 
    ? 'seedProUserWithStripeSubscription'
    : 'seedStarterUserWithStripeSubscription'
    
  cy.task(taskName, { email: options.email }).then((result: any) => {
    expect(result.ok).to.be.true
  })
})
```

## Test Data Cleanup

### Cleanup Strategies

```typescript
// cypress/tasks/cleanup.ts
export async function cleanupTestData() {
  console.log('🧹 Cleaning up test data...')
  
  try {
    // Delete test users from Stripe
    const customers = await stripe.customers.list({
      limit: 100,
      expand: ['data.subscriptions']
    })
    
    for (const customer of customers.data) {
      if (customer.metadata?.test_source === 'cypress') {
        // Cancel subscriptions first
        if (customer.subscriptions?.data.length) {
          for (const subscription of customer.subscriptions.data) {
            await stripe.subscriptions.cancel(subscription.id)
          }
        }
        
        // Delete customer
        await stripe.customers.del(customer.id)
        console.log(`✅ Deleted test customer: ${customer.id}`)
      }
    }

    // Delete test users from database
    const { error } = await supabaseAdmin
      .from('users')
      .delete()
      .like('email', '%cypress%')

    if (error) {
      console.error('Database cleanup error:', error)
    } else {
      console.log('✅ Database cleanup completed')
    }

    return { ok: true }

  } catch (error) {
    console.error('❌ Cleanup failed:', error)
    return { 
      ok: false, 
      error: error instanceof Error ? error.message : 'Unknown error' 
    }
  }
}
```

## Best Practices for E2E Testing

### Test Isolation

1. **Use unique emails** for each test run
2. **Clear cookies/localStorage** before each test
3. **Seed fresh data** for each test scenario
4. **Clean up test data** after test runs

### Reliability Patterns

1. **Wait for elements** to be visible before interacting
2. **Use data-testid** attributes for stable selectors
3. **Intercept API calls** to verify behavior
4. **Add explicit waits** for async operations
5. **Reload pages** to verify persistence

### Error Handling

1. **Test both success and failure scenarios**
2. **Verify error messages** are displayed correctly
3. **Test network failures** with intercept mocking
4. **Handle timeout scenarios** appropriately

## Next Steps

In the next module, we'll cover integration testing patterns for testing individual API endpoints and business logic functions.

## Key Takeaways

- Use deterministic seed helpers for consistent test data
- Implement auth bridge pattern for reliable authentication
- Intercept API calls to verify behavior and add test context
- Simulate webhooks by calling handlers directly
- Verify both Stripe and database state in tests
- Clean up test data to avoid pollution
- Use unique identifiers to prevent test interference
- Test both happy path and error scenarios
- Implement proper waits and element visibility checks
- Structure tests for maintainability and reliability
