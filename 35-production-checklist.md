# Production Deployment Checklist

## Overview

This module provides a comprehensive pre-launch checklist for taking your Stripe billing system live safely. Based on production-tested patterns, we'll cover validation procedures, security checks, and deployment strategies.

## Pre-Launch Validation Checklist

### Stripe Configuration Validation

```bash
# Verify Stripe keys are properly configured
✅ STRIPE_SECRET_KEY starts with sk_live_
✅ STRIPE_WEBHOOK_SECRET is set for production webhook endpoint
✅ STRIPE_PUBLISHABLE_KEY starts with pk_live_
✅ All price IDs in plan configuration exist in live mode
✅ Webhook endpoint is accessible from internet
✅ Webhook events are properly configured in Stripe dashboard
```

### Database Schema Validation

```sql
-- Verify essential tables exist with proper structure
✅ subscriptions table has all required columns
✅ users table is properly linked to auth.users
✅ RLS policies are enabled and tested
✅ Indexes are created for performance
✅ Constraints prevent invalid data
✅ Database migrations are applied
```

### Environment Variables Checklist

```bash
# Production environment variables
✅ SUPABASE_URL points to production project
✅ SUPABASE_SERVICE_ROLE_KEY is production service role key
✅ APP_URL is production domain
✅ STRIPE_SECRET_KEY is live mode key
✅ STRIPE_WEBHOOK_SECRET matches production webhook
✅ All environment variables are properly secured
```

## Security Validation

### API Security Checks

```typescript
// Verify authentication is working
const securityChecks = [
  {
    name: 'Webhook signature verification',
    test: async () => {
      // Test with invalid signature should fail
      const response = await fetch('/api/webhooks/stripe', {
        method: 'POST',
        headers: { 'stripe-signature': 'invalid' },
        body: JSON.stringify({ type: 'test' })
      })
      return response.status === 400
    }
  },
  {
    name: 'User authentication required',
    test: async () => {
      // API calls without auth should fail
      const response = await fetch('/api/billing/upgrade', {
        method: 'POST',
        body: JSON.stringify({ newPlanId: 'pro' })
      })
      return response.status === 401
    }
  },
  {
    name: 'RLS policies active',
    test: async () => {
      // Verify users can only access their own data
      // This should be tested with real user tokens
      return true // Implement actual RLS test
    }
  }
]

// Run security validation
for (const check of securityChecks) {
  const passed = await check.test()
  console.log(`${passed ? '✅' : '❌'} ${check.name}`)
}
```

### Data Protection Validation

```typescript
// Verify sensitive data is properly protected
const dataProtectionChecks = [
  'Stripe secret keys not exposed in client code',
  'Database credentials properly secured',
  'User data isolated with RLS',
  'API endpoints require authentication',
  'Webhook endpoints verify signatures',
  'Error messages don\'t leak sensitive data'
]
```

## Functional Testing in Production

### Smoke Test Suite

```typescript
// Production smoke tests (safe operations only)
describe('Production Smoke Tests', () => {
  // Use a dedicated test account for production validation
  const testEmail = 'production-test@yourcompany.com'
  
  it('should create checkout session', async () => {
    const response = await fetch('/api/billing/create-checkout-session', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${productionTestToken}`
      },
      body: JSON.stringify({
        userId: productionTestUserId,
        planId: 'starter',
        successUrl: 'https://yourapp.com/billing?success=true',
        cancelUrl: 'https://yourapp.com/billing?canceled=true',
        billingInterval: 'month'
      })
    })

    expect(response.status).toBe(200)
    
    const data = await response.json()
    expect(data.url).toContain('checkout.stripe.com')
  })

  it('should create customer portal session', async () => {
    const response = await fetch('/api/billing/create-portal-session', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${productionTestToken}`
      },
      body: JSON.stringify({
        userId: productionTestUserId
      })
    })

    expect(response.status).toBe(200)
    
    const data = await response.json()
    expect(data.url).toContain('billing.stripe.com')
  })

  it('should retrieve subscription details', async () => {
    // Test subscription retrieval without making changes
    const response = await fetch('/api/billing/subscription', {
      headers: {
        'Authorization': `Bearer ${productionTestToken}`
      }
    })

    expect(response.status).toBe(200)
  })
})
```

## Deployment Validation Steps

### Step 1: Environment Verification

```bash
#!/bin/bash
# Production deployment validation script

echo "🔍 Validating production environment..."

# Check environment variables
if [[ $STRIPE_SECRET_KEY != sk_live_* ]]; then
  echo "❌ STRIPE_SECRET_KEY must be live mode key"
  exit 1
fi

if [[ $STRIPE_PUBLISHABLE_KEY != pk_live_* ]]; then
  echo "❌ STRIPE_PUBLISHABLE_KEY must be live mode key"
  exit 1
fi

if [[ -z $STRIPE_WEBHOOK_SECRET ]]; then
  echo "❌ STRIPE_WEBHOOK_SECRET is required"
  exit 1
fi

echo "✅ Environment variables validated"
```

### Step 2: Database Validation

```sql
-- Run these queries to validate production database
-- Check that essential tables exist
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
AND table_name IN ('users', 'subscriptions');

-- Verify RLS is enabled
SELECT schemaname, tablename, rowsecurity 
FROM pg_tables 
WHERE schemaname = 'public' 
AND tablename IN ('users', 'subscriptions');

-- Check for test data in production (should be empty)
SELECT COUNT(*) as test_users 
FROM users 
WHERE email LIKE '%test%' OR email LIKE '%cypress%';
```

### Step 3: API Health Checks

```typescript
// app/api/health/billing/route.ts
export async function GET() {
  const checks = []
  
  try {
    // Test Stripe connection
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })
    
    await stripe.customers.list({ limit: 1 })
    checks.push({ name: 'Stripe API', status: 'ok' })
  } catch (error) {
    checks.push({ name: 'Stripe API', status: 'error', error: error.message })
  }

  try {
    // Test database connection
    const supabase = createServerServiceRoleClient()
    const { error } = await supabase.from('subscriptions').select('id').limit(1)
    
    if (error) throw error
    checks.push({ name: 'Database', status: 'ok' })
  } catch (error) {
    checks.push({ name: 'Database', status: 'error', error: error.message })
  }

  const allHealthy = checks.every(check => check.status === 'ok')
  
  return new Response(
    JSON.stringify({
      status: allHealthy ? 'healthy' : 'unhealthy',
      checks: checks,
      timestamp: new Date().toISOString()
    }),
    {
      status: allHealthy ? 200 : 500,
      headers: { 'Content-Type': 'application/json' }
    }
  )
}
```

## Webhook Endpoint Validation

### Webhook Connectivity Test

```bash
#!/bin/bash
# Test webhook endpoint connectivity

WEBHOOK_URL="https://yourapp.com/api/webhooks/stripe"
WEBHOOK_SECRET="whsec_your_production_secret"

# Test webhook endpoint responds
curl -X POST $WEBHOOK_URL \
  -H "Content-Type: application/json" \
  -H "Stripe-Signature: invalid" \
  -d '{"type":"test"}' \
  --fail-with-body

# Should return 400 for invalid signature (proves endpoint is working)
```

### Webhook Event Configuration

```typescript
// Verify these events are configured in Stripe Dashboard
const requiredWebhookEvents = [
  'invoice.payment_succeeded',
  'invoice.payment_failed', 
  'customer.subscription.created',
  'customer.subscription.updated',
  'customer.subscription.deleted',
  'subscription_schedule.created',
  'subscription_schedule.updated', 
  'subscription_schedule.released'
]

// Production webhook endpoint should listen for all these events
```

## Performance Validation

### Load Testing Preparation

```typescript
// Basic performance validation
describe('Production Performance', () => {
  it('should handle checkout session creation under load', async () => {
    const startTime = Date.now()
    
    // Create multiple checkout sessions concurrently
    const promises = Array.from({ length: 10 }, () =>
      fetch('/api/billing/create-checkout-session', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          userId: testUserId,
          planId: 'starter',
          successUrl: 'https://yourapp.com/billing?success=true',
          cancelUrl: 'https://yourapp.com/billing?canceled=true'
        })
      })
    )

    const responses = await Promise.all(promises)
    const endTime = Date.now()

    // All should succeed
    responses.forEach(response => {
      expect(response.status).toBe(200)
    })

    // Should complete within reasonable time
    expect(endTime - startTime).toBeLessThan(5000) // 5 seconds
    
    console.log(`✅ Created 10 checkout sessions in ${endTime - startTime}ms`)
  })
})
```

## Monitoring Setup Validation

### Error Tracking Verification

```typescript
// Verify error tracking is working
export async function validateErrorTracking() {
  try {
    // Intentionally trigger a handled error
    await fetch('/api/billing/upgrade', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ newPlanId: 'invalid_plan' })
    })

    // Check that error was logged/tracked
    // This depends on your error tracking service
    console.log('✅ Error tracking validation completed')
  } catch (error) {
    console.error('❌ Error tracking validation failed:', error)
  }
}
```

### Webhook Monitoring Setup

```typescript
// Webhook health monitoring
export async function setupWebhookMonitoring() {
  // This would integrate with your monitoring service
  const webhookMetrics = {
    endpoint: '/api/webhooks/stripe',
    expectedEvents: [
      'invoice.payment_succeeded',
      'subscription_schedule.created'
    ],
    alertThresholds: {
      failureRate: 0.05, // Alert if >5% failures
      responseTime: 5000, // Alert if >5s response time
      missedEvents: 10    // Alert if >10 missed events
    }
  }

  console.log('📊 Webhook monitoring configured:', webhookMetrics)
}
```

## Go-Live Procedure

### Deployment Steps

```bash
#!/bin/bash
# Production deployment procedure

echo "🚀 Starting production deployment..."

# 1. Backup current state
echo "📦 Creating backup..."
# Your backup procedure here

# 2. Deploy application
echo "🔄 Deploying application..."
# Your deployment command here

# 3. Run health checks
echo "🏥 Running health checks..."
curl -f https://yourapp.com/api/health/billing

# 4. Validate webhook endpoint
echo "🪝 Validating webhook endpoint..."
curl -X POST https://yourapp.com/api/webhooks/stripe \
  -H "Stripe-Signature: invalid" \
  -d '{"type":"test"}' \
  --fail-with-body

# 5. Run smoke tests
echo "💨 Running smoke tests..."
npm run test:production:smoke

# 6. Monitor for errors
echo "👀 Monitoring deployment..."
# Watch logs for 5 minutes
timeout 300 tail -f /var/log/app.log

echo "✅ Production deployment completed"
```

### Rollback Plan

```bash
#!/bin/bash
# Rollback procedure if deployment fails

echo "🔄 Rolling back deployment..."

# 1. Revert to previous version
# Your rollback command here

# 2. Restore database if needed
# Your database restore procedure here

# 3. Verify rollback worked
curl -f https://yourapp.com/api/health/billing

echo "✅ Rollback completed"
```

## Post-Deployment Validation

### Customer Journey Testing

```typescript
// Test critical customer journeys in production
const productionJourneyTests = [
  {
    name: 'New customer subscription',
    steps: [
      'Visit pricing page',
      'Select plan',
      'Complete checkout',
      'Verify subscription active'
    ]
  },
  {
    name: 'Existing customer upgrade',
    steps: [
      'Login to billing page',
      'Select higher plan',
      'Confirm upgrade',
      'Verify immediate access'
    ]
  },
  {
    name: 'Customer portal access',
    steps: [
      'Click manage payment',
      'Access Stripe portal',
      'Update payment method',
      'Return to app'
    ]
  }
]
```

### Business Metrics Validation

```typescript
// Verify business metrics are tracking correctly
export async function validateBusinessMetrics() {
  try {
    // Check that subscriptions are being created
    const { data: recentSubs } = await supabase
      .from('subscriptions')
      .select('created_at, plan_id')
      .gte('created_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())
      .order('created_at', { ascending: false })

    console.log(`📊 Recent subscriptions (24h): ${recentSubs?.length || 0}`)

    // Check webhook processing
    const { data: recentWebhooks } = await supabase
      .from('webhook_events') // If you track webhook events
      .select('event_type, processed_at')
      .gte('processed_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())

    console.log(`🪝 Recent webhooks (24h): ${recentWebhooks?.length || 0}`)

    return { subscriptions: recentSubs?.length || 0, webhooks: recentWebhooks?.length || 0 }

  } catch (error) {
    console.error('❌ Business metrics validation failed:', error)
    return null
  }
}
```

## Launch Day Monitoring

### Critical Metrics to Watch

```typescript
// Metrics to monitor on launch day
const launchMetrics = {
  // Billing API performance
  checkoutSessionCreation: {
    successRate: '>95%',
    responseTime: '<2s',
    errorRate: '<5%'
  },

  // Webhook processing
  webhookProcessing: {
    successRate: '>99%',
    responseTime: '<5s',
    retryRate: '<10%'
  },

  // Database performance
  databaseQueries: {
    subscriptionLookups: '<500ms',
    userQueries: '<200ms',
    connectionPool: '<80% utilization'
  },

  // Business metrics
  businessKPIs: {
    newSubscriptions: 'Track hourly',
    upgrades: 'Track hourly', 
    downgrades: 'Track daily',
    churnRate: 'Track daily'
  }
}
```

### Alert Configuration

```typescript
// Production alert thresholds
const productionAlerts = {
  critical: [
    'Webhook endpoint down >5 minutes',
    'Database connection failures >5 in 10 minutes',
    'Stripe API errors >10 in 10 minutes',
    'Checkout session failures >50% in 10 minutes'
  ],
  
  warning: [
    'Webhook processing >10s response time',
    'Subscription lookup >1s response time', 
    'Failed payments >10 in 1 hour',
    'Upgrade API errors >5% in 1 hour'
  ],

  info: [
    'New subscription created',
    'Plan upgrade completed',
    'Scheduled downgrade processed',
    'Customer portal session created'
  ]
}
```

## Testing Production Readiness

### Pre-Launch Test Suite

```bash
#!/bin/bash
# Run comprehensive pre-launch tests

echo "🧪 Running pre-launch test suite..."

# 1. Run all unit tests
echo "🔬 Unit tests..."
npm run test:unit

# 2. Run integration tests with production-like data
echo "🔗 Integration tests..."
npm run test:integration

# 3. Run E2E tests against staging
echo "🎭 E2E tests..."
npm run test:e2e:staging

# 4. Run security tests
echo "🔒 Security tests..."
npm run test:security

# 5. Run performance tests
echo "⚡ Performance tests..."
npm run test:performance

echo "✅ Pre-launch test suite completed"
```

### Staging Environment Validation

```typescript
// Validate staging environment matches production setup
const stagingValidation = {
  async validateEnvironment() {
    // Check that staging uses test mode but production configuration
    const isTestMode = process.env.STRIPE_SECRET_KEY?.startsWith('sk_test_')
    const hasProductionStructure = await this.checkProductionStructure()
    
    return {
      testMode: isTestMode,
      productionStructure: hasProductionStructure,
      ready: isTestMode && hasProductionStructure
    }
  },

  async checkProductionStructure() {
    try {
      // Verify database schema matches production
      const { data: tables } = await supabase
        .from('information_schema.tables')
        .select('table_name')
        .eq('table_schema', 'public')

      const requiredTables = ['users', 'subscriptions', 'usage_ledger']
      const hasAllTables = requiredTables.every(table => 
        tables?.some(t => t.table_name === table)
      )

      return hasAllTables
    } catch (error) {
      return false
    }
  }
}
```

## Launch Communication Plan

### Internal Team Checklist

```markdown
## Launch Day Team Responsibilities

### Engineering Team
- [ ] Monitor application logs and error rates
- [ ] Watch webhook processing metrics
- [ ] Respond to alerts within 15 minutes
- [ ] Have rollback plan ready

### Product Team  
- [ ] Monitor customer signup flow
- [ ] Track conversion rates
- [ ] Watch for user-reported issues
- [ ] Prepare customer communication if needed

### Support Team
- [ ] Monitor support channels for billing issues
- [ ] Have escalation process ready
- [ ] Document common issues and solutions
- [ ] Test customer portal access
```

### Customer Communication

```typescript
// Prepare customer communication templates
const launchCommunication = {
  prelaunch: {
    subject: 'Billing System Upgrade - What You Need to Know',
    content: `
      We're upgrading our billing system to provide you with:
      - Improved payment processing
      - Better subscription management  
      - Enhanced security
      
      No action required - your subscription will continue uninterrupted.
    `
  },

  postlaunch: {
    subject: 'Billing System Upgrade Complete',
    content: `
      Our billing system upgrade is complete! You can now:
      - Manage your subscription at [billing page]
      - Update payment methods securely
      - View detailed billing history
      
      Questions? Contact support at support@yourcompany.com
    `
  },

  issues: {
    subject: 'Billing System Issue - We\'re On It',
    content: `
      We're experiencing a temporary issue with our billing system.
      - Your subscription remains active
      - No payments will be processed during the issue
      - We'll update you within 1 hour
      
      Estimated resolution: [time]
    `
  }
}
```

## Next Steps

In the next module, we'll cover ongoing environment management and maintaining test vs production separation.

## Key Takeaways

- **Validate all environment variables** before going live
- **Test critical user journeys** in production-like environment
- **Set up comprehensive monitoring** for launch day
- **Have a rollback plan** ready and tested
- **Verify webhook endpoint** connectivity and configuration
- **Run security validation** to ensure data protection
- **Monitor business metrics** to validate system is working
- **Prepare team communication** and responsibilities
- **Test with real Stripe live mode** in staging first
- **Document launch procedures** for future deployments
