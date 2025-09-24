# Environment Setup and Security

## Overview

This module covers setting up your Stripe environment variables, configuring test vs live mode, and implementing security best practices. Proper environment setup is critical for both development and production deployments.

## Required Environment Variables

Based on your codebase analysis, here are the essential environment variables:

### Core Stripe Variables

```bash
# Stripe API Keys
STRIPE_SECRET_KEY=sk_test_your_secret_key_here
STRIPE_WEBHOOK_SECRET=whsec_your_webhook_secret_here

# Optional: Publishable key for client-side operations
STRIPE_PUBLISHABLE_KEY=pk_test_your_publishable_key_here
```

### Supabase Integration Variables

```bash
# Supabase Configuration
SUPABASE_URL=https://your-project-id.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your_service_role_key_here
SUPABASE_ANON_KEY=your_anon_key_here
```

### Application Configuration

```bash
# Application URLs
APP_URL=http://localhost:3000
```

## Test vs Live Mode Configuration

### Development Environment (.env.local)

```bash
# Test mode keys for development
STRIPE_SECRET_KEY=sk_test_51ABC...
STRIPE_WEBHOOK_SECRET=whsec_123...
STRIPE_PUBLISHABLE_KEY=pk_test_51ABC...

# Local development URLs
APP_URL=http://localhost:3000
```

### Production Environment

```bash
# Live mode keys for production
STRIPE_SECRET_KEY=sk_live_51ABC...
STRIPE_WEBHOOK_SECRET=whsec_456...
STRIPE_PUBLISHABLE_KEY=pk_live_51ABC...

# Production URLs
APP_URL=https://your-domain.com
```

## Stripe API Version Configuration

Your codebase uses a specific API version for consistency:

```typescript
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
  apiVersion: '2025-08-27.basil'  // Pinned version from your codebase
})
```

**Why pin the API version?**
- Prevents breaking changes from automatic updates
- Ensures consistent behavior across environments
- Allows controlled upgrades when ready

## Webhook Endpoint Configuration

### Local Development Setup

For local development, you'll need to expose your webhook endpoint:

```bash
# Install Stripe CLI
stripe listen --forward-to localhost:3000/api/webhooks/stripe

# This will give you a webhook secret like:
# whsec_1234567890abcdef...
```

### Production Webhook Setup

1. **Create webhook endpoint** in Stripe Dashboard
2. **Set endpoint URL**: `https://your-domain.com/api/webhooks/stripe`
3. **Select events** to listen for:
   ```
   customer.subscription.created
   customer.subscription.updated
   customer.subscription.deleted
   invoice.payment_succeeded
   invoice.payment_failed
   subscription_schedule.created
   subscription_schedule.updated
   subscription_schedule.released
   ```

## Security Best Practices

### 1. Webhook Signature Verification

Your codebase implements proper webhook verification:

```typescript
export async function handleWebhookRequest(request: Request) {
  try {
    const body = await request.text()
    const signature = request.headers.get('stripe-signature')

    if (!signature) {
      return new Response(
        JSON.stringify({ error: 'Missing stripe-signature header' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Verify webhook signature
    const event = stripe.webhooks.constructEvent(body, signature, webhookSecret)
    
    // Process event only after verification
    await processWebhookEvent(event)
    
    return new Response(
      JSON.stringify({ received: true }),
      { headers: { 'Content-Type': 'application/json' } }
    )
    
  } catch (err) {
    console.error('❌ Webhook signature verification failed:', err)
    return new Response(
      JSON.stringify({ error: 'Invalid signature' }),
      { status: 400, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

### 2. Environment Variable Validation

Add validation to ensure required variables are present:

```typescript
// lib/config/stripe.ts
export function validateStripeConfig() {
  const requiredVars = [
    'STRIPE_SECRET_KEY',
    'STRIPE_WEBHOOK_SECRET'
  ]
  
  const missing = requiredVars.filter(varName => !process.env[varName])
  
  if (missing.length > 0) {
    throw new Error(`Missing required environment variables: ${missing.join(', ')}`)
  }
  
  // Validate key format
  const secretKey = process.env.STRIPE_SECRET_KEY!
  if (!secretKey.startsWith('sk_test_') && !secretKey.startsWith('sk_live_')) {
    throw new Error('Invalid STRIPE_SECRET_KEY format')
  }
}
```

### 3. Service Role vs User Context

Your codebase correctly separates contexts:

```typescript
// For webhook handling (service role)
const supabase = createServerServiceRoleClient()

// For user operations (user context)
const supabase = createServerUserClient()
```

**When to use each:**
- **Service Role**: Webhooks, admin operations, system tasks
- **User Context**: User-initiated API calls, RLS-protected operations

### 4. API Key Security

```typescript
// Never expose secret keys in client code
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
  apiVersion: '2025-08-27.basil'
})

// Only use publishable keys on the client
const stripePublishable = process.env.STRIPE_PUBLISHABLE_KEY!
```

## Development Workflow

### 1. Local Development Setup

```bash
# 1. Copy environment template
cp .env.example .env.local

# 2. Fill in your Stripe test keys
# Edit .env.local with your actual values

# 3. Start Stripe webhook forwarding
stripe listen --forward-to localhost:3000/api/webhooks/stripe

# 4. Start your development server
npm start  # or your framework's start command
```

### 2. Testing Webhook Integration

```bash
# Trigger a test webhook
stripe trigger customer.subscription.created

# Check your application logs for webhook processing
```

### 3. Environment Validation

Add a health check endpoint:

```typescript
// Health check endpoint for Stripe connection
export async function handleStripeHealthCheck() {
  try {
    // Test Stripe connection
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })
    
    await stripe.customers.list({ limit: 1 })
    
    return new Response(
      JSON.stringify({ 
        status: 'ok', 
        mode: process.env.STRIPE_SECRET_KEY?.startsWith('sk_test_') ? 'test' : 'live'
      }),
      { headers: { 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    return new Response(
      JSON.stringify({ 
        status: 'error', 
        error: 'Stripe connection failed' 
      }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

## Production Deployment Checklist

### Pre-Deployment
- [ ] Switch to live Stripe keys
- [ ] Update webhook endpoint URL
- [ ] Verify all environment variables are set
- [ ] Test webhook signature verification
- [ ] Validate API key permissions

### Post-Deployment
- [ ] Test webhook delivery
- [ ] Verify subscription creation flow
- [ ] Check error logging and monitoring
- [ ] Test payment processing
- [ ] Validate database synchronization

## Common Environment Issues

### 1. Webhook Signature Failures

**Problem**: Webhooks failing signature verification
**Solution**: 
- Ensure webhook secret matches Stripe dashboard
- Check that raw request body is used (not parsed JSON)
- Verify endpoint URL is correct

### 2. Mixed Test/Live Data

**Problem**: Test customers in live mode or vice versa
**Solution**:
- Use separate databases for test/live
- Clear separation of environment variables
- Validate key prefixes (`sk_test_` vs `sk_live_`)

### 3. CORS Issues

**Problem**: Client-side Stripe calls failing
**Solution**:
- Ensure publishable key is properly set
- Check CORS configuration for API routes
- Verify domain whitelist in Stripe dashboard

## Monitoring and Logging

### Webhook Event Logging

```typescript
// Log all webhook events for debugging
console.log('👋🏼 Received Stripe webhook event:', event.type)
console.log('Event ID:', event.id)
console.log('Created:', new Date(event.created * 1000).toISOString())

// Log lightweight snapshot
const object = event.data?.object ?? null
if (object) {
  console.log('Object type:', object.object)
  console.log('Object ID:', object.id)
}
```

### Error Tracking

```typescript
try {
  await processWebhookEvent(event)
} catch (error) {
  console.error('❌ Webhook processing failed:', error)
  
  // Send to error tracking service
  if (process.env.NODE_ENV === 'production') {
    await errorTrackingService.captureException(error, {
      context: 'stripe_webhook',
      eventType: event.type,
      eventId: event.id
    })
  }
}
```

## Next Steps

In the next module, we'll cover database design patterns for storing subscription and billing data.

## Key Takeaways

- Pin Stripe API versions for consistency
- Always verify webhook signatures
- Separate test and live environments completely
- Use appropriate Supabase client contexts
- Implement comprehensive error handling and logging
- Validate environment configuration on startup
