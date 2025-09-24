# Advanced Webhook Security

## Overview

This module covers advanced webhook security patterns, including signature verification best practices, protecting against replay attacks, implementing webhook authentication, and securing webhook endpoints in production environments.

## Webhook Security Fundamentals

Webhook security is critical because webhooks:
- Process sensitive billing data
- Update subscription statuses
- Handle payment confirmations
- Manage customer data

### Security Threats

1. **Man-in-the-Middle Attacks**: Intercepted webhook data
2. **Replay Attacks**: Reusing captured webhook events
3. **Spoofed Webhooks**: Fake events from malicious actors
4. **Data Tampering**: Modified webhook payloads
5. **Timing Attacks**: Exploiting signature verification timing

## Enhanced Signature Verification

### Robust Verification Implementation

```typescript
// lib/webhook-security.ts
import crypto from 'crypto'
import Stripe from 'stripe'

export class WebhookSecurityManager {
  private readonly webhookSecret: string
  private readonly tolerance: number = 300 // 5 minutes

  constructor(webhookSecret: string) {
    this.webhookSecret = webhookSecret
    
    if (!webhookSecret) {
      throw new Error('Webhook secret is required for security')
    }
  }

  /**
   * Verify webhook signature with enhanced security checks
   */
  public verifyWebhookSignature(
    payload: string,
    signature: string,
    timestamp?: number
  ): { valid: boolean; event?: Stripe.Event; error?: string } {
    
    try {
      // Basic signature verification
      const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
        apiVersion: '2025-08-27.basil'
      })

      const event = stripe.webhooks.constructEvent(payload, signature, this.webhookSecret)
      
      // Additional security checks
      const securityChecks = this.performSecurityChecks(event, timestamp)
      if (!securityChecks.valid) {
        return { valid: false, error: securityChecks.error }
      }

      return { valid: true, event }

    } catch (error) {
      console.error('❌ Webhook signature verification failed:', error)
      
      if (error instanceof Stripe.errors.StripeSignatureVerificationError) {
        return { valid: false, error: 'Invalid webhook signature' }
      }
      
      return { valid: false, error: 'Webhook verification failed' }
    }
  }

  /**
   * Additional security checks beyond basic signature verification
   */
  private performSecurityChecks(
    event: Stripe.Event,
    timestamp?: number
  ): { valid: boolean; error?: string } {
    
    // Check event timestamp to prevent replay attacks
    const eventTimestamp = event.created
    const currentTimestamp = Math.floor(Date.now() / 1000)
    
    if (Math.abs(currentTimestamp - eventTimestamp) > this.tolerance) {
      return { 
        valid: false, 
        error: `Event timestamp too old or too far in future. Event: ${eventTimestamp}, Current: ${currentTimestamp}` 
      }
    }

    // Validate event structure
    if (!event.id || !event.type || !event.data) {
      return { valid: false, error: 'Invalid event structure' }
    }

    // Check for suspicious event patterns
    if (this.isSuspiciousEvent(event)) {
      return { valid: false, error: 'Suspicious event pattern detected' }
    }

    return { valid: true }
  }

  /**
   * Detect suspicious event patterns
   */
  private isSuspiciousEvent(event: Stripe.Event): boolean {
    // Check for events with suspicious metadata
    const object = event.data.object as any
    
    if (object.metadata) {
      // Flag events with potentially malicious metadata
      const suspiciousKeys = ['script', 'eval', 'javascript:', 'data:', 'vbscript:']
      const metadataString = JSON.stringify(object.metadata).toLowerCase()
      
      for (const key of suspiciousKeys) {
        if (metadataString.includes(key)) {
          console.warn(`🚨 Suspicious metadata detected in event ${event.id}:`, object.metadata)
          return true
        }
      }
    }

    return false
  }

  /**
   * Rate limiting for webhook endpoints
   */
  public async checkRateLimit(
    identifier: string,
    windowMs: number = 60000, // 1 minute
    maxRequests: number = 100
  ): Promise<{ allowed: boolean; resetTime?: number }> {
    
    // Implementation would use Redis or in-memory store
    // This is a simplified example
    const key = `webhook_rate_limit:${identifier}`
    const now = Date.now()
    
    try {
      // Get current request count from cache
      const cached = await this.getFromCache(key)
      
      if (!cached) {
        await this.setInCache(key, { count: 1, windowStart: now }, windowMs)
        return { allowed: true }
      }

      const { count, windowStart } = cached
      
      // Check if window has expired
      if (now - windowStart > windowMs) {
        await this.setInCache(key, { count: 1, windowStart: now }, windowMs)
        return { allowed: true }
      }

      // Check if within rate limit
      if (count < maxRequests) {
        await this.setInCache(key, { count: count + 1, windowStart }, windowMs)
        return { allowed: true }
      }

      // Rate limit exceeded
      const resetTime = windowStart + windowMs
      return { allowed: false, resetTime }

    } catch (error) {
      console.error('Rate limit check failed:', error)
      return { allowed: true } // Fail open for availability
    }
  }

  private async getFromCache(key: string): Promise<any> {
    // Implementation depends on your caching solution
    return null
  }

  private async setInCache(key: string, value: any, ttlMs: number): Promise<void> {
    // Implementation depends on your caching solution
  }
}
```

### Enhanced Webhook Handler

```typescript
// webhooks/stripe-secure.ts (Enhanced Security Version)
import { WebhookSecurityManager } from './lib/webhook-security'
import { WebhookEventProcessor } from './lib/webhook-processor'
import { WebhookLogger } from './lib/webhook-logger'

const securityManager = new WebhookSecurityManager(process.env.STRIPE_WEBHOOK_SECRET!)
const eventProcessor = new WebhookEventProcessor()
const logger = new WebhookLogger()

export async function handleSecureStripeWebhook(request: Request): Promise<Response> {
  const startTime = Date.now()
  const requestId = crypto.randomUUID()
  
  console.log(`🚀 Webhook ${requestId} started`)

  try {
    // Get client IP for rate limiting and logging
    const clientIP = request.headers.get('x-forwarded-for') || 
                    request.headers.get('x-real-ip') || 
                    'unknown'

    // Rate limiting check
    const rateLimit = await securityManager.checkRateLimit(clientIP)
    if (!rateLimit.allowed) {
      console.log(`🚫 Rate limit exceeded for IP: ${clientIP}`)
      return new Response(
        JSON.stringify({ error: 'Rate limit exceeded' }),
        { 
          status: 429,
          headers: {
            'Content-Type': 'application/json',
            'Retry-After': Math.ceil((rateLimit.resetTime! - Date.now()) / 1000).toString()
          }
        }
      )
    }

    // Get request body and signature
    const body = await request.text()
    const signature = request.headers.get('stripe-signature')

    if (!signature) {
      console.log('❌ Missing stripe-signature header')
      await logger.logSecurityEvent({
        type: 'missing_signature',
        ip: clientIP,
        requestId,
        severity: 'high'
      })
      
      return new Response(
      JSON.stringify(
        { error: 'Missing stripe-signature header' },
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Enhanced signature verification
    const verification = securityManager.verifyWebhookSignature(body, signature)
    
    if (!verification.valid) {
      console.error('❌ Webhook signature verification failed:', verification.error)
      
      await logger.logSecurityEvent({
        type: 'invalid_signature',
        ip: clientIP,
        requestId,
        error: verification.error,
        severity: 'critical'
      })
      
      return new Response(
      JSON.stringify(
        { error: 'Invalid signature' },
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const event = verification.event!
    console.log(`✅ Webhook ${requestId} verified: ${event.type}`)

    // Check for duplicate events (idempotency)
    const isDuplicate = await eventProcessor.isDuplicateEvent(event.id)
    if (isDuplicate) {
      console.log(`🔄 Duplicate event ignored: ${event.id}`)
      return new Response(
      JSON.stringify({ received: true, duplicate: true })
    }

    // Log webhook event
    await logger.logWebhookEvent({
      eventId: event.id,
      eventType: event.type,
      requestId,
      ip: clientIP,
      processingStarted: new Date().toISOString()
    })

    // Process the event
    const processingResult = await eventProcessor.processEvent(event, requestId)
    
    if (!processingResult.success) {
      console.error(`❌ Event processing failed: ${processingResult.error}`)
      
      await logger.logProcessingError({
        eventId: event.id,
        requestId,
        error: processingResult.error,
        processingTime: Date.now() - startTime
      })
      
      return new Response(
      JSON.stringify(
        { error: 'Event processing failed' },
        { status: 500, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Mark event as processed
    await eventProcessor.markEventProcessed(event.id, requestId)

    const processingTime = Date.now() - startTime
    console.log(`✅ Webhook ${requestId} completed in ${processingTime}ms`)

    await logger.logWebhookSuccess({
      eventId: event.id,
      requestId,
      processingTime
    })

    return new Response(
      JSON.stringify({ 
      received: true, 
      eventId: event.id,
      processingTime 
    })

  } catch (error) {
    const processingTime = Date.now() - startTime
    console.error(`❌ Webhook ${requestId} failed after ${processingTime}ms:`, error)

    await logger.logWebhookError({
      requestId,
      error: error instanceof Error ? error.message : 'Unknown error',
      processingTime
    })

    return new Response(
      JSON.stringify({ 
      error: 'Webhook processing failed' 
    ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Webhook Event Processing

### Idempotent Event Processor

```typescript
// lib/webhook-processor.ts
export class WebhookEventProcessor {
  private processedEvents = new Map<string, { timestamp: number; requestId: string }>()
  private readonly eventTTL = 24 * 60 * 60 * 1000 // 24 hours

  /**
   * Check if event has already been processed
   */
  public async isDuplicateEvent(eventId: string): Promise<boolean> {
    // Check in-memory cache first
    const cached = this.processedEvents.get(eventId)
    if (cached && (Date.now() - cached.timestamp) < this.eventTTL) {
      return true
    }

    // Check database for persistence across restarts
    const supabase = createServerServiceRoleClient()
    const { data } = await supabase
      .from('processed_webhook_events')
      .select('id')
      .eq('stripe_event_id', eventId)
      .gte('processed_at', new Date(Date.now() - this.eventTTL).toISOString())
      .single()

    return !!data
  }

  /**
   * Process webhook event with error handling
   */
  public async processEvent(
    event: Stripe.Event,
    requestId: string
  ): Promise<{ success: boolean; error?: string; result?: any }> {
    
    try {
      console.log(`🔄 Processing event ${event.id} (${event.type})`)

      let result: any

      // Route to appropriate handler
      switch (event.type) {
        case 'checkout.session.completed':
          result = await this.handleCheckoutSessionCompleted(event.data.object, requestId)
          break

        case 'customer.subscription.created':
          result = await this.handleSubscriptionCreated(event.data.object, requestId)
          break

        case 'customer.subscription.updated':
          result = await this.handleSubscriptionUpdated(event.data.object, requestId)
          break

        case 'customer.subscription.deleted':
          result = await this.handleSubscriptionDeleted(event.data.object, requestId)
          break

        case 'invoice.payment_succeeded':
          result = await this.handleInvoicePaymentSucceeded(event.data.object, requestId)
          break

        case 'invoice.payment_failed':
          result = await this.handleInvoicePaymentFailed(event.data.object, requestId)
          break

        case 'subscription_schedule.created':
          result = await this.handleSubscriptionScheduleCreated(event.data.object, requestId)
          break

        case 'subscription_schedule.updated':
          result = await this.handleSubscriptionScheduleUpdated(event.data.object, requestId)
          break

        case 'subscription_schedule.released':
          result = await this.handleSubscriptionScheduleReleased(event.data.object, requestId)
          break

        case 'customer.updated':
          result = await this.handleCustomerUpdated(event.data.object, requestId)
          break

        case 'payment_method.attached':
          result = await this.handlePaymentMethodAttached(event.data.object, requestId)
          break

        default:
          console.log(`ℹ️ Unhandled event type: ${event.type}`)
          result = { handled: false, eventType: event.type }
      }

      console.log(`✅ Event ${event.id} processed successfully`)
      return { success: true, result }

    } catch (error) {
      console.error(`❌ Event ${event.id} processing failed:`, error)
      return { 
        success: false, 
        error: error instanceof Error ? error.message : 'Processing failed' 
      }
    }
  }

  /**
   * Mark event as processed for idempotency
   */
  public async markEventProcessed(eventId: string, requestId: string): Promise<void> {
    // Store in memory cache
    this.processedEvents.set(eventId, {
      timestamp: Date.now(),
      requestId
    })

    // Store in database for persistence
    const supabase = createServerServiceRoleClient()
    await supabase
      .from('processed_webhook_events')
      .insert({
        stripe_event_id: eventId,
        request_id: requestId,
        processed_at: new Date().toISOString()
      })
  }

  /**
   * Enhanced event handlers with security context
   */
  private async handleInvoicePaymentSucceeded(invoice: any, requestId: string) {
    // Add security context to existing handler
    const context = {
      requestId,
      securityLevel: 'high',
      requiresValidation: true
    }

    return await handleInvoicePaymentPaid(invoice, context)
  }

  // ... other enhanced handlers
}
```

## Webhook Authentication

### API Key Authentication for Webhooks

```typescript
// lib/webhook-auth.ts
export class WebhookAuthManager {
  /**
   * Validate webhook source beyond signature verification
   */
  public async validateWebhookSource(
    event: Stripe.Event,
    request: Request
  ): Promise<{ valid: boolean; reason?: string }> {
    
    // Check User-Agent header
    const userAgent = request.headers.get('user-agent')
    if (!userAgent || !userAgent.includes('Stripe')) {
      return { valid: false, reason: 'Invalid User-Agent header' }
    }

    // Validate event ID format
    if (!event.id.startsWith('evt_')) {
      return { valid: false, reason: 'Invalid event ID format' }
    }

    // Check event age (prevent very old events)
    const eventAge = Date.now() / 1000 - event.created
    if (eventAge > 86400) { // 24 hours
      return { valid: false, reason: 'Event too old' }
    }

    // Validate against known Stripe IP ranges (optional)
    const clientIP = request.headers.get('x-forwarded-for')?.split(',')[0] || 'unknown'
    if (process.env.VALIDATE_STRIPE_IPS === 'true') {
      const isValidStripeIP = await this.validateStripeIP(clientIP)
      if (!isValidStripeIP) {
        return { valid: false, reason: 'Request not from Stripe IP range' }
      }
    }

    return { valid: true }
  }

  private async validateStripeIP(ip: string): Promise<boolean> {
    // Stripe IP ranges (would need to be kept updated)
    const stripeIPRanges = [
      '54.187.174.169/32',
      '54.187.205.235/32',
      '54.187.216.72/32',
      // ... other Stripe IPs
    ]

    // Implementation would check if IP is in allowed ranges
    // This is a simplified example
    return true
  }
}
```

## Webhook Monitoring and Alerting

### Webhook Health Monitor

```typescript
// lib/webhook-monitoring.ts
export class WebhookHealthMonitor {
  private readonly alertThresholds = {
    failureRate: 0.05, // 5% failure rate
    avgProcessingTime: 5000, // 5 seconds
    eventBacklog: 100 // 100 unprocessed events
  }

  /**
   * Monitor webhook health metrics
   */
  public async checkWebhookHealth(): Promise<{
    healthy: boolean
    metrics: any
    alerts: string[]
  }> {
    
    try {
      const supabase = createServerServiceRoleClient()
      const now = new Date()
      const oneHourAgo = new Date(now.getTime() - 60 * 60 * 1000)

      // Get webhook metrics for last hour
      const { data: events } = await supabase
        .from('webhook_events')
        .select('*')
        .gte('created_at', oneHourAgo.toISOString())

      if (!events || events.length === 0) {
        return {
          healthy: true,
          metrics: { totalEvents: 0 },
          alerts: []
        }
      }

      // Calculate metrics
      const totalEvents = events.length
      const failedEvents = events.filter(e => e.status === 'failed').length
      const failureRate = failedEvents / totalEvents
      
      const processingTimes = events
        .filter(e => e.processing_time_ms)
        .map(e => e.processing_time_ms)
      
      const avgProcessingTime = processingTimes.length > 0
        ? processingTimes.reduce((sum, time) => sum + time, 0) / processingTimes.length
        : 0

      // Check for alerts
      const alerts: string[] = []
      
      if (failureRate > this.alertThresholds.failureRate) {
        alerts.push(`High failure rate: ${(failureRate * 100).toFixed(1)}%`)
      }
      
      if (avgProcessingTime > this.alertThresholds.avgProcessingTime) {
        alerts.push(`Slow processing: ${avgProcessingTime.toFixed(0)}ms average`)
      }

      // Check for event backlog
      const { data: unprocessedEvents } = await supabase
        .from('webhook_events')
        .select('id')
        .eq('status', 'pending')
        .lt('created_at', new Date(now.getTime() - 5 * 60 * 1000).toISOString()) // 5 minutes old

      const backlogCount = unprocessedEvents?.length || 0
      if (backlogCount > this.alertThresholds.eventBacklog) {
        alerts.push(`Event backlog: ${backlogCount} unprocessed events`)
      }

      const metrics = {
        totalEvents,
        failedEvents,
        failureRate: failureRate * 100,
        avgProcessingTime,
        backlogCount
      }

      return {
        healthy: alerts.length === 0,
        metrics,
        alerts
      }

    } catch (error) {
      console.error('❌ Webhook health check failed:', error)
      return {
        healthy: false,
        metrics: {},
        alerts: ['Health check failed']
      }
    }
  }

  /**
   * Send alerts when webhook health degrades
   */
  public async sendHealthAlerts(healthCheck: any): Promise<void> {
    if (healthCheck.healthy) return

    try {
      // Send to monitoring service
      await monitoringService.alert({
        title: 'Webhook Health Alert',
        description: `Webhook system health degraded: ${healthCheck.alerts.join(', ')}`,
        severity: 'high',
        metrics: healthCheck.metrics
      })

      // Send email alerts for critical issues
      const criticalAlerts = healthCheck.alerts.filter((alert: string) => 
        alert.includes('failure rate') || alert.includes('backlog')
      )

      if (criticalAlerts.length > 0) {
        await emailService.send({
          to: process.env.ALERT_EMAIL!,
          template: 'webhook_health_alert',
          data: {
            alerts: criticalAlerts,
            metrics: healthCheck.metrics,
            timestamp: new Date().toISOString()
          }
        })
      }

      console.log('🚨 Webhook health alerts sent')
    } catch (error) {
      console.error('❌ Failed to send health alerts:', error)
    }
  }
}
```

## Security Best Practices

### Production Security Checklist

```typescript
// lib/webhook-security-checklist.ts
export async function validateWebhookSecurity(): Promise<{
  passed: boolean
  checks: Array<{ name: string; passed: boolean; message: string }>
}> {
  
  const checks = []

  // Check 1: Webhook secret is configured
  checks.push({
    name: 'Webhook Secret Configuration',
    passed: !!process.env.STRIPE_WEBHOOK_SECRET,
    message: process.env.STRIPE_WEBHOOK_SECRET 
      ? 'Webhook secret is configured'
      : 'STRIPE_WEBHOOK_SECRET environment variable is missing'
  })

  // Check 2: HTTPS enforcement
  checks.push({
    name: 'HTTPS Enforcement',
    passed: process.env.NODE_ENV === 'production' 
      ? process.env.APP_URL?.startsWith('https://') || false
      : true,
    message: process.env.NODE_ENV === 'production'
      ? 'HTTPS is enforced in production'
      : 'HTTPS enforcement skipped in development'
  })

  // Check 3: Rate limiting configuration
  checks.push({
    name: 'Rate Limiting',
    passed: !!process.env.REDIS_URL || !!process.env.UPSTASH_REDIS_REST_URL,
    message: 'Rate limiting backend is configured'
  })

  // Check 4: Webhook endpoint accessibility
  try {
    const webhookUrl = `${process.env.APP_URL}/api/webhooks/stripe`
    const response = await fetch(webhookUrl, { method: 'HEAD' })
    
    checks.push({
      name: 'Webhook Endpoint Accessibility',
      passed: response.status !== 404,
      message: response.status !== 404 
        ? 'Webhook endpoint is accessible'
        : 'Webhook endpoint returns 404'
    })
  } catch (error) {
    checks.push({
      name: 'Webhook Endpoint Accessibility',
      passed: false,
      message: 'Cannot reach webhook endpoint'
    })
  }

  // Check 5: Database security
  const supabase = createServerServiceRoleClient()
  try {
    await supabase.from('subscriptions').select('id').limit(1)
    checks.push({
      name: 'Database Connectivity',
      passed: true,
      message: 'Database is accessible'
    })
  } catch (error) {
    checks.push({
      name: 'Database Connectivity',
      passed: false,
      message: 'Database connection failed'
    })
  }

  const allPassed = checks.every(check => check.passed)

  return { passed: allPassed, checks }
}
```

## Testing Webhook Security

### Security Test Suite

```typescript
// __tests__/security/webhook-security.test.ts
import { WebhookSecurityManager } from '@/lib/webhook-security'
import Stripe from 'stripe'

describe('Webhook Security', () => {
  let securityManager: WebhookSecurityManager
  let stripe: Stripe

  beforeAll(() => {
    securityManager = new WebhookSecurityManager(process.env.STRIPE_WEBHOOK_SECRET!)
    stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })
  })

  describe('Signature Verification', () => {
    it('should verify valid signatures', () => {
      const payload = JSON.stringify({ test: 'data' })
      const signature = stripe.webhooks.generateTestHeaderString({
        payload,
        secret: process.env.STRIPE_WEBHOOK_SECRET!
      })

      const result = securityManager.verifyWebhookSignature(payload, signature)
      expect(result.valid).toBe(true)
    })

    it('should reject invalid signatures', () => {
      const payload = JSON.stringify({ test: 'data' })
      const invalidSignature = 'invalid_signature'

      const result = securityManager.verifyWebhookSignature(payload, invalidSignature)
      expect(result.valid).toBe(false)
      expect(result.error).toContain('Invalid webhook signature')
    })

    it('should reject tampered payloads', () => {
      const originalPayload = JSON.stringify({ test: 'data' })
      const tamperedPayload = JSON.stringify({ test: 'tampered_data' })
      
      const signature = stripe.webhooks.generateTestHeaderString({
        payload: originalPayload,
        secret: process.env.STRIPE_WEBHOOK_SECRET!
      })

      const result = securityManager.verifyWebhookSignature(tamperedPayload, signature)
      expect(result.valid).toBe(false)
    })
  })

  describe('Replay Attack Protection', () => {
    it('should reject old events', () => {
      const oldEvent = {
        id: 'evt_old',
        type: 'test.event',
        created: Math.floor(Date.now() / 1000) - 7200, // 2 hours ago
        data: { object: {} }
      } as Stripe.Event

      const payload = JSON.stringify(oldEvent)
      const signature = stripe.webhooks.generateTestHeaderString({
        payload,
        secret: process.env.STRIPE_WEBHOOK_SECRET!
      })

      const result = securityManager.verifyWebhookSignature(payload, signature)
      expect(result.valid).toBe(false)
      expect(result.error).toContain('too old')
    })
  })

  describe('Rate Limiting', () => {
    it('should allow requests within rate limit', async () => {
      const result = await securityManager.checkRateLimit('test_ip_1')
      expect(result.allowed).toBe(true)
    })

    it('should block requests exceeding rate limit', async () => {
      const testIP = 'test_ip_excessive'
      
      // Make requests up to limit
      for (let i = 0; i < 100; i++) {
        await securityManager.checkRateLimit(testIP)
      }

      // Next request should be blocked
      const result = await securityManager.checkRateLimit(testIP)
      expect(result.allowed).toBe(false)
      expect(result.resetTime).toBeDefined()
    })
  })
})
```

## Next Steps

In the next module, we'll cover webhook reliability patterns including idempotency, retries, and error handling.

## Key Takeaways

- Implement robust signature verification with additional security checks
- Protect against replay attacks with timestamp validation
- Use rate limiting to prevent webhook abuse
- Monitor webhook health and performance metrics
- Implement comprehensive logging for security events
- Validate webhook sources beyond signature verification
- Handle suspicious events and metadata patterns
- Test security measures thoroughly including attack scenarios
- Set up alerting for webhook security issues
- Follow production security best practices for webhook endpoints
