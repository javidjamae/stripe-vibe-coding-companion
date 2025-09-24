# Environment Management: Test vs Production

## Overview

This module covers managing test and production environments for Stripe integration, including environment separation, data isolation, and safe environment transitions. Based on production-tested patterns, we'll explore environment management strategies that prevent costly mistakes.

## Environment Separation Strategy

### Our Recommended Approach

Your codebase demonstrates a clean separation between test and production environments:

```typescript
// Environment detection pattern from your codebase
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
  apiVersion: '2025-08-27.basil'
})

// Environment is determined by the key prefix
const isTestMode = process.env.STRIPE_SECRET_KEY?.startsWith('sk_test_')
const isLiveMode = process.env.STRIPE_SECRET_KEY?.startsWith('sk_live_')
```

### Environment Configuration Matrix

| Environment | Stripe Mode | Database | Purpose |
|-------------|-------------|----------|---------|
| **Local Development** | Test Mode | Local/Dev DB | Feature development |
| **Staging** | Test Mode | Staging DB | Integration testing |
| **Production** | Live Mode | Production DB | Real customers |

## Environment Variables Management

### Development Environment (.env.local)

```bash
# Local development configuration
NODE_ENV=development

# Stripe Test Mode
STRIPE_SECRET_KEY=sk_test_51ABC123...
STRIPE_WEBHOOK_SECRET=whsec_test_123...
STRIPE_PUBLISHABLE_KEY=pk_test_51ABC123...

# Local Supabase
SUPABASE_URL=http://localhost:54321
SUPABASE_SERVICE_ROLE_KEY=your_local_service_role_key
SUPABASE_URL=http://localhost:54321
SUPABASE_ANON_KEY=your_local_anon_key

# Local URLs
APP_URL=http://localhost:3000
```

### Staging Environment

```bash
# Staging configuration
NODE_ENV=staging

# Stripe Test Mode (same as dev)
STRIPE_SECRET_KEY=sk_test_51ABC123...
STRIPE_WEBHOOK_SECRET=whsec_staging_456...
STRIPE_PUBLISHABLE_KEY=pk_test_51ABC123...

# Staging Supabase
SUPABASE_URL=https://staging-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=staging_service_role_key
SUPABASE_URL=https://staging-project.supabase.co
SUPABASE_ANON_KEY=staging_anon_key

# Staging URLs
APP_URL=https://staging.yourapp.com
```

### Production Environment

```bash
# Production configuration
NODE_ENV=production

# Stripe Live Mode
STRIPE_SECRET_KEY=sk_live_51DEF456...
STRIPE_WEBHOOK_SECRET=whsec_live_789...
STRIPE_PUBLISHABLE_KEY=pk_live_51DEF456...

# Production Supabase
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=production_service_role_key
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=production_anon_key

# Production URLs
APP_URL=https://yourapp.com
```

## Environment Validation

### Startup Validation

```typescript
// lib/config/environment-validation.ts
export function validateEnvironment() {
  const errors: string[] = []
  
  // Validate Stripe configuration
  const stripeKey = process.env.STRIPE_SECRET_KEY
  if (!stripeKey) {
    errors.push('STRIPE_SECRET_KEY is required')
  } else {
    const isTest = stripeKey.startsWith('sk_test_')
    const isLive = stripeKey.startsWith('sk_live_')
    
    if (!isTest && !isLive) {
      errors.push('STRIPE_SECRET_KEY must start with sk_test_ or sk_live_')
    }
    
    // Validate environment consistency
    if (process.env.NODE_ENV === 'production' && isTest) {
      errors.push('Production environment cannot use test Stripe keys')
    }
    
    if (process.env.NODE_ENV !== 'production' && isLive) {
      console.warn('⚠️  Warning: Using live Stripe keys in non-production environment')
    }
  }

  // Validate webhook secret
  if (!process.env.STRIPE_WEBHOOK_SECRET) {
    errors.push('STRIPE_WEBHOOK_SECRET is required')
  }

  // Validate Supabase configuration
  if (!process.env.SUPABASE_URL) {
    errors.push('SUPABASE_URL is required')
  }
  
  if (!process.env.SUPABASE_SERVICE_ROLE_KEY) {
    errors.push('SUPABASE_SERVICE_ROLE_KEY is required')
  }

  // Validate app URL
  if (!process.env.APP_URL) {
    errors.push('APP_URL is required')
  }

  if (errors.length > 0) {
    throw new Error(`Environment validation failed:\n${errors.join('\n')}`)
  }

  console.log('✅ Environment validation passed')
  
  return {
    environment: process.env.NODE_ENV,
    stripeMode: stripeKey?.startsWith('sk_test_') ? 'test' : 'live',
    supabaseUrl: process.env.SUPABASE_URL,
    appUrl: process.env.APP_URL
  }
}

// Call validation on app startup
if (typeof window === 'undefined') { // Server-side only
  try {
    validateEnvironment()
  } catch (error) {
    console.error('💥 Environment validation failed:', error)
    process.exit(1)
  }
}
```

## Data Isolation Patterns

### Test Data Identification

```typescript
// Pattern for identifying test data in any environment
export const TestDataMarkers = {
  // Email patterns for test users
  isTestEmail: (email: string): boolean => {
    return email.includes('test') || 
           email.includes('cypress') || 
           email.includes('staging') ||
           email.includes('@example.com')
  },

  // Stripe metadata for test customers
  testMetadata: {
    test_source: 'cypress',
    environment: 'test',
    created_by: 'automated_test'
  },

  // Database markers
  isTestUser: (user: any): boolean => {
    return this.isTestEmail(user.email) ||
           user.metadata?.test_source === 'cypress'
  }
}
```

### Environment-Specific Cleanup

```typescript
// Safe cleanup that respects environment boundaries
export async function cleanupEnvironmentData(environment: 'development' | 'staging') {
  if (environment === 'production') {
    throw new Error('Cannot run cleanup on production environment')
  }

  console.log(`🧹 Cleaning up ${environment} environment...`)

  try {
    // Only clean up clearly marked test data
    const { data: testUsers } = await supabase
      .from('users')
      .select('id, email')
      .or('email.ilike.%test%,email.ilike.%cypress%,email.ilike.%staging%')

    console.log(`Found ${testUsers?.length || 0} test users to clean up`)

    if (testUsers && testUsers.length > 0) {
      // Delete test users (cascades to subscriptions)
      const { error } = await supabase
        .from('users')
        .delete()
        .in('id', testUsers.map(u => u.id))

      if (error) {
        console.error('Database cleanup error:', error)
      } else {
        console.log(`✅ Cleaned up ${testUsers.length} test users`)
      }
    }

    // Clean up Stripe test data
    if (process.env.STRIPE_SECRET_KEY?.startsWith('sk_test_')) {
      await cleanupStripeTestData()
    }

    return { ok: true, cleanedUsers: testUsers?.length || 0 }

  } catch (error) {
    console.error('❌ Environment cleanup failed:', error)
    return { ok: false, error: error.message }
  }
}

async function cleanupStripeTestData() {
  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  // Only run if in test mode
  if (!process.env.STRIPE_SECRET_KEY?.startsWith('sk_test_')) {
    console.log('⚠️  Skipping Stripe cleanup - not in test mode')
    return
  }

  const customers = await stripe.customers.list({
    limit: 100,
    expand: ['data.subscriptions']
  })

  let cleanedCount = 0
  
  for (const customer of customers.data) {
    const isTestCustomer = customer.metadata?.test_source === 'cypress' ||
                          customer.email?.includes('test') ||
                          customer.email?.includes('cypress')

    if (isTestCustomer) {
      // Cancel subscriptions first
      if (customer.subscriptions?.data.length) {
        for (const subscription of customer.subscriptions.data) {
          await stripe.subscriptions.cancel(subscription.id)
        }
      }
      
      // Delete customer
      await stripe.customers.del(customer.id)
      cleanedCount++
    }
  }

  console.log(`✅ Cleaned up ${cleanedCount} test customers from Stripe`)
}
```

## Environment Transition Procedures

### Test to Production Migration

```typescript
// Safe migration from test to production
export async function migrateToProduction() {
  console.log('🚀 Preparing production migration...')

  // 1. Validate current environment is ready
  const currentEnv = validateEnvironment()
  if (currentEnv.stripeMode !== 'test') {
    throw new Error('Can only migrate from test environment')
  }

  // 2. Backup current configuration
  const backupConfig = {
    timestamp: new Date().toISOString(),
    environment: currentEnv,
    planConfiguration: getAllPlans(),
    // Add other configuration that needs backing up
  }

  console.log('📦 Configuration backed up:', backupConfig.timestamp)

  // 3. Validate production Stripe setup
  await validateProductionStripeSetup()

  // 4. Validate production database
  await validateProductionDatabase()

  // 5. Run pre-migration tests
  await runPreMigrationTests()

  console.log('✅ Production migration validation completed')
  console.log('🎯 Ready to deploy with live Stripe keys')

  return {
    ready: true,
    backup: backupConfig,
    checklist: [
      'Update environment variables to live mode',
      'Deploy application',
      'Run post-deployment validation',
      'Monitor for 24 hours'
    ]
  }
}

async function validateProductionStripeSetup() {
  // Verify live mode Stripe configuration exists
  const liveStripeKey = process.env.STRIPE_LIVE_SECRET_KEY
  if (!liveStripeKey?.startsWith('sk_live_')) {
    throw new Error('STRIPE_LIVE_SECRET_KEY must be configured')
  }

  // Test connection to live Stripe (read-only operation)
  const stripe = new Stripe(liveStripeKey, { apiVersion: '2025-08-27.basil' })
  
  try {
    await stripe.customers.list({ limit: 1 })
    console.log('✅ Live Stripe connection validated')
  } catch (error) {
    throw new Error(`Live Stripe connection failed: ${error.message}`)
  }

  // Verify live mode price IDs exist
  const plans = getAllPlans()
  for (const [planId, config] of Object.entries(plans)) {
    if (config.monthly?.stripePriceId) {
      try {
        await stripe.prices.retrieve(config.monthly.stripePriceId)
      } catch (error) {
        throw new Error(`Live price ID not found: ${config.monthly.stripePriceId} for ${planId} monthly`)
      }
    }
    
    if (config.annual?.stripePriceId) {
      try {
        await stripe.prices.retrieve(config.annual.stripePriceId)
      } catch (error) {
        throw new Error(`Live price ID not found: ${config.annual.stripePriceId} for ${planId} annual`)
      }
    }
  }

  console.log('✅ Live mode price IDs validated')
}
```

## Environment-Specific Features

### Test Mode Helpers

```typescript
// Development and testing helpers
export const TestModeHelpers = {
  // Create test subscription without real payment
  async createTestSubscription(userId: string, planId: string) {
    if (!process.env.STRIPE_SECRET_KEY?.startsWith('sk_test_')) {
      throw new Error('Test subscription creation only allowed in test mode')
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY, {
      apiVersion: '2025-08-27.basil'
    })

    // Create customer
    const customer = await stripe.customers.create({
      email: `test-${userId}@example.com`,
      metadata: { userId, test_source: 'development' }
    })

    // Create subscription with test price
    const priceId = getStripePriceId(planId, 'month')
    const subscription = await stripe.subscriptions.create({
      customer: customer.id,
      items: [{ price: priceId }],
      metadata: { userId, planId, test_source: 'development' }
    })

    return { customer, subscription }
  },

  // Reset test environment
  async resetTestEnvironment() {
    if (process.env.NODE_ENV === 'production') {
      throw new Error('Cannot reset production environment')
    }

    console.log('🔄 Resetting test environment...')
    
    // Clean up test data
    await cleanupEnvironmentData(process.env.NODE_ENV as any)
    
    // Reset database to clean state
    await resetTestDatabase()
    
    console.log('✅ Test environment reset completed')
  }
}
```

### Production Mode Safeguards

```typescript
// Production safety checks
export const ProductionSafeguards = {
  // Prevent accidental test operations in production
  validateProductionOperation(operation: string) {
    if (process.env.NODE_ENV === 'production') {
      const dangerousOperations = [
        'cleanup_all_data',
        'reset_database',
        'create_test_users',
        'simulate_webhook'
      ]

      if (dangerousOperations.includes(operation)) {
        throw new Error(`Operation ${operation} is not allowed in production`)
      }
    }
  },

  // Validate live mode for production operations
  validateLiveMode() {
    if (process.env.NODE_ENV === 'production') {
      if (!process.env.STRIPE_SECRET_KEY?.startsWith('sk_live_')) {
        throw new Error('Production environment must use live Stripe keys')
      }
    }
  },

  // Check for test data in production
  async auditProductionData() {
    if (process.env.NODE_ENV !== 'production') {
      return { clean: true }
    }

    const supabase = createServerServiceRoleClient()
    
    // Check for test users
    const { data: testUsers } = await supabase
      .from('users')
      .select('email')
      .or('email.ilike.%test%,email.ilike.%cypress%,email.ilike.%example.com%')

    if (testUsers && testUsers.length > 0) {
      console.warn('⚠️  Test users found in production:', testUsers)
      return { clean: false, testUsers }
    }

    return { clean: true }
  }
}
```

## Database Environment Management

### Environment-Specific Migrations

```sql
-- Migration with environment awareness
DO $$
BEGIN
  -- Only run certain operations in specific environments
  IF current_setting('app.environment', true) = 'production' THEN
    -- Production-specific setup
    INSERT INTO subscriptions (user_id, plan_id, status) 
    SELECT id, 'free', 'active' 
    FROM users 
    WHERE NOT EXISTS (
      SELECT 1 FROM subscriptions WHERE user_id = users.id
    );
  ELSE
    -- Development/staging setup
    -- Create test data, etc.
  END IF;
END $$;
```

### Environment Configuration in Database

```sql
-- Store environment configuration in database
CREATE TABLE IF NOT EXISTS environment_config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  environment TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Insert environment-specific configuration
INSERT INTO environment_config (key, value, environment) VALUES
('stripe_mode', 'test', 'development'),
('stripe_mode', 'test', 'staging'),
('stripe_mode', 'live', 'production'),
('webhook_timeout', '30', 'development'),
('webhook_timeout', '10', 'production');
```

## Environment Switching Procedures

### Safe Environment Transition

```typescript
// Procedure for switching environments safely
export async function switchEnvironment(
  fromEnv: 'development' | 'staging' | 'production',
  toEnv: 'development' | 'staging' | 'production'
) {
  console.log(`🔄 Switching from ${fromEnv} to ${toEnv}...`)

  // Validate transition is allowed
  const allowedTransitions = {
    development: ['staging'],
    staging: ['production'],
    production: [] // No transitions from production
  }

  if (!allowedTransitions[fromEnv].includes(toEnv)) {
    throw new Error(`Transition from ${fromEnv} to ${toEnv} not allowed`)
  }

  // Pre-transition validation
  await validateEnvironmentReadiness(toEnv)

  // Create transition checklist
  const checklist = generateTransitionChecklist(fromEnv, toEnv)
  
  console.log('📋 Transition checklist:')
  checklist.forEach((item, index) => {
    console.log(`${index + 1}. ${item}`)
  })

  return {
    ready: true,
    checklist,
    nextSteps: [
      'Update environment variables',
      'Deploy application',
      'Run validation tests',
      'Monitor for issues'
    ]
  }
}

function generateTransitionChecklist(fromEnv: string, toEnv: string): string[] {
  const baseChecklist = [
    'Backup current configuration',
    'Update environment variables',
    'Validate new environment connectivity',
    'Run smoke tests'
  ]

  if (toEnv === 'production') {
    return [
      ...baseChecklist,
      'Switch to live Stripe keys',
      'Update webhook endpoint URL',
      'Verify live mode price IDs exist',
      'Test with small transaction',
      'Monitor for 24 hours'
    ]
  }

  return baseChecklist
}
```

## Environment Monitoring

### Environment Health Checks

```typescript
// app/api/health/environment/route.ts
export async function GET() {
  try {
    const environment = process.env.NODE_ENV
    const stripeMode = process.env.STRIPE_SECRET_KEY?.startsWith('sk_test_') ? 'test' : 'live'
    
    // Environment consistency check
    const isConsistent = (environment === 'production' && stripeMode === 'live') ||
                        (environment !== 'production' && stripeMode === 'test')

    // Database connectivity
    const supabase = createServerServiceRoleClient()
    const { error: dbError } = await supabase.from('users').select('id').limit(1)
    
    // Stripe connectivity
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })
    
    let stripeHealthy = false
    try {
      await stripe.customers.list({ limit: 1 })
      stripeHealthy = true
    } catch (error) {
      console.error('Stripe health check failed:', error)
    }

    const health = {
      environment,
      stripeMode,
      consistent: isConsistent,
      database: !dbError,
      stripe: stripeHealthy,
      timestamp: new Date().toISOString()
    }

    const isHealthy = health.consistent && health.database && health.stripe

    return new Response(
      JSON.stringify(health),
      {
        status: isHealthy ? 200 : 500,
        headers: { 'Content-Type': 'application/json' }
      }
    )

  } catch (error) {
    return new Response(
      JSON.stringify({
        error: 'Health check failed',
        details: error.message
      }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

### Environment Alerts

```typescript
// Environment monitoring and alerting
export const EnvironmentMonitoring = {
  // Alert on environment inconsistencies
  async checkEnvironmentConsistency() {
    const environment = process.env.NODE_ENV
    const stripeMode = process.env.STRIPE_SECRET_KEY?.startsWith('sk_test_') ? 'test' : 'live'
    
    const issues = []

    // Check for dangerous combinations
    if (environment === 'production' && stripeMode === 'test') {
      issues.push('CRITICAL: Production environment using test Stripe keys')
    }

    if (environment !== 'production' && stripeMode === 'live') {
      issues.push('WARNING: Non-production environment using live Stripe keys')
    }

    // Check for test data in production
    if (environment === 'production') {
      const audit = await ProductionSafeguards.auditProductionData()
      if (!audit.clean) {
        issues.push(`WARNING: Test data found in production: ${audit.testUsers?.length} test users`)
      }
    }

    return {
      consistent: issues.length === 0,
      issues
    }
  },

  // Monitor key metrics by environment
  async getEnvironmentMetrics() {
    const supabase = createServerServiceRoleClient()
    
    // Get subscription counts by environment
    const { data: subscriptions } = await supabase
      .from('subscriptions')
      .select('plan_id, status, created_at')
      .gte('created_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())

    const metrics = {
      environment: process.env.NODE_ENV,
      stripeMode: process.env.STRIPE_SECRET_KEY?.startsWith('sk_test_') ? 'test' : 'live',
      last24Hours: {
        totalSubscriptions: subscriptions?.length || 0,
        byPlan: subscriptions?.reduce((acc, sub) => {
          acc[sub.plan_id] = (acc[sub.plan_id] || 0) + 1
          return acc
        }, {} as Record<string, number>) || {},
        byStatus: subscriptions?.reduce((acc, sub) => {
          acc[sub.status] = (acc[sub.status] || 0) + 1
          return acc
        }, {} as Record<string, number>) || {}
      }
    }

    return metrics
  }
}
```

## Alternative: Multi-Environment Configuration

If you wanted to support multiple environments in a single deployment:

### Dynamic Environment Configuration

```typescript
// lib/config/dynamic-environment.ts (Alternative approach)
export class EnvironmentConfig {
  private static instance: EnvironmentConfig
  private config: any

  static getInstance(): EnvironmentConfig {
    if (!EnvironmentConfig.instance) {
      EnvironmentConfig.instance = new EnvironmentConfig()
    }
    return EnvironmentConfig.instance
  }

  private constructor() {
    this.loadConfig()
  }

  private loadConfig() {
    const environment = process.env.NODE_ENV || 'development'
    
    this.config = {
      development: {
        stripe: {
          secretKey: process.env.STRIPE_TEST_SECRET_KEY,
          webhookSecret: process.env.STRIPE_TEST_WEBHOOK_SECRET,
          mode: 'test'
        },
        database: {
          url: process.env.DEV_SUPABASE_URL,
          serviceRoleKey: process.env.DEV_SUPABASE_SERVICE_ROLE_KEY
        }
      },
      staging: {
        stripe: {
          secretKey: process.env.STRIPE_TEST_SECRET_KEY,
          webhookSecret: process.env.STRIPE_STAGING_WEBHOOK_SECRET,
          mode: 'test'
        },
        database: {
          url: process.env.STAGING_SUPABASE_URL,
          serviceRoleKey: process.env.STAGING_SUPABASE_SERVICE_ROLE_KEY
        }
      },
      production: {
        stripe: {
          secretKey: process.env.STRIPE_LIVE_SECRET_KEY,
          webhookSecret: process.env.STRIPE_LIVE_WEBHOOK_SECRET,
          mode: 'live'
        },
        database: {
          url: process.env.PROD_SUPABASE_URL,
          serviceRoleKey: process.env.PROD_SUPABASE_SERVICE_ROLE_KEY
        }
      }
    }[environment]

    if (!this.config) {
      throw new Error(`Unknown environment: ${environment}`)
    }
  }

  getStripeConfig() {
    return this.config.stripe
  }

  getDatabaseConfig() {
    return this.config.database
  }
}
```

## Next Steps

In the next module, we'll cover monitoring setup and alerting for your billing system.

## Key Takeaways

- **Maintain strict environment separation** between test and production
- **Validate environment configuration** on application startup
- **Use environment-specific safeguards** to prevent dangerous operations
- **Clean up test data regularly** to prevent environment pollution
- **Monitor environment consistency** and alert on misconfigurations
- **Plan environment transitions carefully** with validation at each step
- **Use test mode for all non-production environments**
- **Audit production data** regularly for test data contamination
- **Document environment procedures** for team consistency
- **Implement rollback procedures** for failed environment transitions
