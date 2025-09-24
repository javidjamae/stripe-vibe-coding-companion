# Webhook Reliability: Idempotency, Retries, and Error Handling

## Overview

This module covers building reliable webhook systems with proper idempotency handling, retry mechanisms, and comprehensive error handling. We'll explore patterns for ensuring webhook processing is bulletproof in production environments.

## Webhook Reliability Fundamentals

### Reliability Challenges

1. **Network Failures**: Temporary connectivity issues
2. **Processing Errors**: Database or business logic failures
3. **Duplicate Events**: Stripe retries can cause duplicates
4. **Partial Failures**: Some operations succeed, others fail
5. **Race Conditions**: Concurrent webhook processing

### Reliability Principles

1. **Idempotency**: Process each event exactly once
2. **Graceful Degradation**: Handle failures without data corruption
3. **Retry Logic**: Smart retry with exponential backoff
4. **Dead Letter Queue**: Handle permanently failed events
5. **Monitoring**: Track reliability metrics

## Idempotency Implementation

### Database-Backed Idempotency

```typescript
// lib/webhook-idempotency.ts
export class WebhookIdempotencyManager {
  private readonly supabase = createServerServiceRoleClient()

  /**
   * Check if event has been processed and get result
   */
  public async checkIdempotency(eventId: string): Promise<{
    alreadyProcessed: boolean
    result?: any
    error?: string
  }> {
    
    try {
      const { data: processedEvent, error } = await this.supabase
        .from('webhook_events')
        .select('*')
        .eq('stripe_event_id', eventId)
        .single()

      if (error && error.code !== 'PGRST116') {
        throw error
      }

      if (processedEvent) {
        console.log(`🔄 Event ${eventId} already processed at ${processedEvent.processed_at}`)
        
        return {
          alreadyProcessed: true,
          result: processedEvent.result,
          error: processedEvent.error_message
        }
      }

      return { alreadyProcessed: false }

    } catch (error) {
      console.error('❌ Idempotency check failed:', error)
      throw error
    }
  }

  /**
   * Record event processing start
   */
  public async recordEventStart(
    eventId: string,
    eventType: string,
    requestId: string
  ): Promise<void> {
    
    try {
      await this.supabase
        .from('webhook_events')
        .insert({
          stripe_event_id: eventId,
          event_type: eventType,
          request_id: requestId,
          status: 'processing',
          started_at: new Date().toISOString(),
          created_at: new Date().toISOString()
        })

      console.log(`📝 Event ${eventId} processing started`)
    } catch (error) {
      // If insert fails due to duplicate, that's actually good (idempotency working)
      if (error.code === '23505') { // Unique violation
        console.log(`🔄 Event ${eventId} already being processed`)
        return
      }
      throw error
    }
  }

  /**
   * Record successful event processing
   */
  public async recordEventSuccess(
    eventId: string,
    result: any,
    processingTimeMs: number
  ): Promise<void> {
    
    try {
      await this.supabase
        .from('webhook_events')
        .update({
          status: 'completed',
          result: result,
          processing_time_ms: processingTimeMs,
          processed_at: new Date().toISOString(),
          completed_at: new Date().toISOString()
        })
        .eq('stripe_event_id', eventId)

      console.log(`✅ Event ${eventId} completed in ${processingTimeMs}ms`)
    } catch (error) {
      console.error('❌ Failed to record event success:', error)
      throw error
    }
  }

  /**
   * Record event processing failure
   */
  public async recordEventFailure(
    eventId: string,
    error: string,
    processingTimeMs: number,
    retryable: boolean = true
  ): Promise<void> {
    
    try {
      await this.supabase
        .from('webhook_events')
        .update({
          status: retryable ? 'failed_retryable' : 'failed_permanent',
          error_message: error,
          processing_time_ms: processingTimeMs,
          failed_at: new Date().toISOString(),
          retry_count: this.supabase.raw('COALESCE(retry_count, 0) + 1')
        })
        .eq('stripe_event_id', eventId)

      console.log(`❌ Event ${eventId} failed: ${error}`)
    } catch (dbError) {
      console.error('❌ Failed to record event failure:', dbError)
    }
  }
}
```

### Enhanced Webhook Handler with Idempotency

```typescript
// Enhanced webhook route with full reliability
export async function handleReliableWebhook(request: Request): Promise<Response> {
  const requestId = crypto.randomUUID()
  const startTime = Date.now()
  const idempotencyManager = new WebhookIdempotencyManager()
  
  console.log(`🚀 Webhook ${requestId} started`)

  try {
    // Signature verification (from previous module)
    const body = await request.text()
    const signature = request.headers.get('stripe-signature')

    if (!signature) {
      return new Response(
        JSON.stringify({ error: 'Missing signature' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const securityManager = new WebhookSecurityManager(process.env.STRIPE_WEBHOOK_SECRET!)
    const verification = securityManager.verifyWebhookSignature(body, signature)
    
    if (!verification.valid) {
      return new Response(
      JSON.stringify({ error: verification.error ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    const event = verification.event!

    // Check idempotency
    const idempotencyCheck = await idempotencyManager.checkIdempotency(event.id)
    
    if (idempotencyCheck.alreadyProcessed) {
      console.log(`🔄 Event ${event.id} already processed, returning cached result`)
      
      if (idempotencyCheck.error) {
        return new Response(
      JSON.stringify({ 
          error: idempotencyCheck.error 
        ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
      }
      
      return new Response(
      JSON.stringify({ 
        received: true, 
        cached: true,
        result: idempotencyCheck.result 
      })
    }

    // Record processing start
    await idempotencyManager.recordEventStart(event.id, event.type, requestId)

    // Process event with error handling
    let result: any
    let processingError: string | null = null

    try {
      result = await processWebhookEventSafely(event, requestId)
    } catch (error) {
      processingError = error instanceof Error ? error.message : 'Processing failed'
      console.error(`❌ Event processing failed:`, error)
    }

    const processingTime = Date.now() - startTime

    if (processingError) {
      // Determine if error is retryable
      const isRetryable = isRetryableError(processingError)
      
      await idempotencyManager.recordEventFailure(
        event.id,
        processingError,
        processingTime,
        isRetryable
      )

      return new Response(
      JSON.stringify({ 
        error: 'Event processing failed',
        retryable: isRetryable
      ),
      { status: isRetryable ? 500 : 400 })
    }

    // Record success
    await idempotencyManager.recordEventSuccess(event.id, result, processingTime)

    return new Response(
      JSON.stringify({ 
      received: true, 
      eventId: event.id,
      processingTime 
    })

  } catch (error) {
    const processingTime = Date.now() - startTime
    console.error(`❌ Webhook ${requestId} failed after ${processingTime}ms:`, error)

    return new Response(
      JSON.stringify({ 
      error: 'Webhook processing failed' 
    ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}

function isRetryableError(error: string): boolean {
  const retryablePatterns = [
    'timeout',
    'connection',
    'network',
    'temporary',
    'rate limit',
    'service unavailable'
  ]

  const errorLower = error.toLowerCase()
  return retryablePatterns.some(pattern => errorLower.includes(pattern))
}
```

## Safe Event Processing

### Transaction-Safe Processing

```typescript
// lib/safe-event-processing.ts
export async function processWebhookEventSafely(
  event: Stripe.Event,
  requestId: string
): Promise<any> {
  
  console.log(`🔒 Safe processing event ${event.id} (${event.type})`)

  const supabase = createServerServiceRoleClient()

  try {
    // Start database transaction
    const { data, error } = await supabase.rpc('begin_webhook_transaction', {
      event_id: event.id,
      request_id: requestId
    })

    if (error) {
      throw new Error(`Transaction start failed: ${error.message}`)
    }

    let result: any

    try {
      // Process event within transaction
      switch (event.type) {
        case 'invoice.payment_succeeded':
          result = await handleInvoicePaymentSucceededSafe(event.data.object, requestId)
          break

        case 'customer.subscription.updated':
          result = await handleSubscriptionUpdatedSafe(event.data.object, requestId)
          break

        case 'subscription_schedule.updated':
          result = await handleSubscriptionScheduleUpdatedSafe(event.data.object, requestId)
          break

        default:
          result = await handleGenericEventSafe(event, requestId)
      }

      // Commit transaction
      await supabase.rpc('commit_webhook_transaction', {
        event_id: event.id,
        request_id: requestId
      })

      console.log(`✅ Event ${event.id} processed safely`)
      return result

    } catch (processingError) {
      // Rollback transaction
      await supabase.rpc('rollback_webhook_transaction', {
        event_id: event.id,
        request_id: requestId,
        error_message: processingError instanceof Error ? processingError.message : 'Unknown error'
      })

      throw processingError
    }

  } catch (error) {
    console.error(`❌ Safe processing failed for event ${event.id}:`, error)
    throw error
  }
}

async function handleInvoicePaymentSucceededSafe(
  invoice: any,
  requestId: string
): Promise<any> {
  
  console.log(`💰 Safe processing invoice payment: ${invoice.id}`)

  if (!invoice.subscription) {
    throw new Error('Invoice has no subscription ID')
  }

  const supabase = createServerServiceRoleClient()

  // Validate subscription exists
  const { data: subscription, error } = await supabase
    .from('subscriptions')
    .select('id, user_id, plan_id')
    .eq('stripe_subscription_id', invoice.subscription)
    .single()

  if (error) {
    throw new Error(`Subscription not found: ${error.message}`)
  }

  // Update subscription with payment info
  const { data: updatedSub, error: updateError } = await supabase
    .from('subscriptions')
    .update({
      status: 'active',
      current_period_start: new Date(invoice.period_start * 1000).toISOString(),
      current_period_end: new Date(invoice.period_end * 1000).toISOString(),
      metadata: {
        last_payment: {
          invoice_id: invoice.id,
          amount: invoice.amount_paid,
          paid_at: new Date().toISOString(),
          request_id: requestId
        }
      },
      updated_at: new Date().toISOString()
    })
    .eq('id', subscription.id)
    .select()
    .single()

  if (updateError) {
    throw new Error(`Subscription update failed: ${updateError.message}`)
  }

  // Record payment event
  await supabase
    .from('payment_events')
    .insert({
      user_id: subscription.user_id,
      subscription_id: subscription.id,
      invoice_id: invoice.id,
      amount_cents: invoice.amount_paid,
      currency: invoice.currency,
      status: 'succeeded',
      processed_at: new Date().toISOString(),
      request_id: requestId
    })

  console.log(`✅ Invoice payment processed safely: ${invoice.id}`)
  return updatedSub
}
```

## Retry and Backoff Strategies

### Smart Retry Logic

```typescript
// lib/webhook-retry.ts
export class WebhookRetryManager {
  private readonly maxRetries = 5
  private readonly baseDelayMs = 1000 // 1 second

  /**
   * Process event with exponential backoff retry
   */
  public async processWithRetry(
    event: Stripe.Event,
    processor: (event: Stripe.Event) => Promise<any>
  ): Promise<{ success: boolean; result?: any; error?: string; attempts: number }> {
    
    let lastError: Error | null = null
    
    for (let attempt = 1; attempt <= this.maxRetries; attempt++) {
      try {
        console.log(`🔄 Processing event ${event.id}, attempt ${attempt}/${this.maxRetries}`)
        
        const result = await processor(event)
        
        console.log(`✅ Event ${event.id} succeeded on attempt ${attempt}`)
        return { success: true, result, attempts: attempt }

      } catch (error) {
        lastError = error instanceof Error ? error : new Error('Unknown error')
        
        console.log(`❌ Event ${event.id} failed on attempt ${attempt}: ${lastError.message}`)

        // Don't retry for certain error types
        if (!this.isRetryableError(lastError)) {
          console.log(`🚫 Event ${event.id} error is not retryable`)
          break
        }

        // Don't retry on last attempt
        if (attempt === this.maxRetries) {
          break
        }

        // Wait before retry with exponential backoff
        const delayMs = this.calculateBackoffDelay(attempt)
        console.log(`⏳ Waiting ${delayMs}ms before retry ${attempt + 1}`)
        
        await this.delay(delayMs)
      }
    }

    return { 
      success: false, 
      error: lastError?.message || 'All retry attempts failed',
      attempts: this.maxRetries
    }
  }

  /**
   * Determine if error is worth retrying
   */
  private isRetryableError(error: Error): boolean {
    const retryablePatterns = [
      'timeout',
      'connection reset',
      'network error',
      'temporary failure',
      'rate limit',
      'service unavailable',
      'internal server error',
      'database connection',
      'lock timeout'
    ]

    const errorMessage = error.message.toLowerCase()
    return retryablePatterns.some(pattern => errorMessage.includes(pattern))
  }

  /**
   * Calculate exponential backoff delay with jitter
   */
  private calculateBackoffDelay(attempt: number): number {
    const exponentialDelay = this.baseDelayMs * Math.pow(2, attempt - 1)
    const jitter = Math.random() * 0.1 * exponentialDelay // Add 10% jitter
    
    return Math.min(exponentialDelay + jitter, 30000) // Cap at 30 seconds
  }

  private delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms))
  }
}
```

### Dead Letter Queue Implementation

```typescript
// lib/dead-letter-queue.ts
export class DeadLetterQueueManager {
  private readonly supabase = createServerServiceRoleClient()

  /**
   * Send failed event to dead letter queue
   */
  public async sendToDeadLetterQueue(
    event: Stripe.Event,
    error: string,
    attempts: number,
    requestId: string
  ): Promise<void> {
    
    console.log(`💀 Sending event ${event.id} to dead letter queue after ${attempts} attempts`)

    try {
      await this.supabase
        .from('webhook_dead_letter_queue')
        .insert({
          stripe_event_id: event.id,
          event_type: event.type,
          event_data: event.data,
          error_message: error,
          failed_attempts: attempts,
          request_id: requestId,
          queued_at: new Date().toISOString(),
          requires_manual_review: this.requiresManualReview(event.type, error)
        })

      // Send alert for critical events
      if (this.isCriticalEvent(event.type)) {
        await this.sendDeadLetterAlert(event, error, attempts)
      }

      console.log(`✅ Event ${event.id} queued for manual review`)

    } catch (dlqError) {
      console.error('❌ Failed to queue event for dead letter processing:', dlqError)
      
      // Last resort: log to external monitoring
      await this.logCriticalFailure(event, error, dlqError)
    }
  }

  /**
   * Process dead letter queue items
   */
  public async processDeadLetterQueue(): Promise<{
    processed: number
    successful: number
    stillFailed: number
  }> {
    
    console.log('🔄 Processing dead letter queue')

    const { data: queueItems, error } = await this.supabase
      .from('webhook_dead_letter_queue')
      .select('*')
      .eq('status', 'pending')
      .lt('queued_at', new Date(Date.now() - 60 * 60 * 1000).toISOString()) // At least 1 hour old
      .limit(50)

    if (error || !queueItems) {
      console.error('❌ Failed to fetch dead letter queue items:', error)
      return { processed: 0, successful: 0, stillFailed: 0 }
    }

    let successful = 0
    let stillFailed = 0

    for (const item of queueItems) {
      try {
        // Reconstruct Stripe event
        const event = {
          id: item.stripe_event_id,
          type: item.event_type,
          data: item.event_data,
          created: Math.floor(new Date(item.queued_at).getTime() / 1000)
        } as Stripe.Event

        // Retry processing
        const result = await processWebhookEventSafely(event, `dlq_${item.id}`)
        
        // Mark as processed
        await this.supabase
          .from('webhook_dead_letter_queue')
          .update({
            status: 'processed',
            processed_at: new Date().toISOString(),
            processing_result: result
          })
          .eq('id', item.id)

        successful++
        console.log(`✅ Dead letter item ${item.id} processed successfully`)

      } catch (retryError) {
        // Mark as permanently failed
        await this.supabase
          .from('webhook_dead_letter_queue')
          .update({
            status: 'permanently_failed',
            retry_error: retryError instanceof Error ? retryError.message : 'Retry failed',
            last_retry_at: new Date().toISOString()
          })
          .eq('id', item.id)

        stillFailed++
        console.log(`❌ Dead letter item ${item.id} still failed: ${retryError}`)
      }
    }

    console.log(`✅ Dead letter queue processed: ${successful} successful, ${stillFailed} still failed`)
    return { processed: queueItems.length, successful, stillFailed }
  }

  private requiresManualReview(eventType: string, error: string): boolean {
    const criticalEventTypes = [
      'invoice.payment_succeeded',
      'customer.subscription.created',
      'customer.subscription.updated'
    ]

    const manualReviewErrors = [
      'data corruption',
      'constraint violation',
      'business logic error'
    ]

    return criticalEventTypes.includes(eventType) || 
           manualReviewErrors.some(pattern => error.toLowerCase().includes(pattern))
  }

  private isCriticalEvent(eventType: string): boolean {
    const criticalEvents = [
      'invoice.payment_succeeded',
      'invoice.payment_failed',
      'customer.subscription.deleted'
    ]

    return criticalEvents.includes(eventType)
  }

  private async sendDeadLetterAlert(
    event: Stripe.Event,
    error: string,
    attempts: number
  ): Promise<void> {
    
    try {
      await emailService.send({
        to: process.env.ALERT_EMAIL!,
        template: 'webhook_dead_letter_alert',
        data: {
          eventId: event.id,
          eventType: event.type,
          error,
          attempts,
          timestamp: new Date().toISOString()
        }
      })
    } catch (alertError) {
      console.error('❌ Failed to send dead letter alert:', alertError)
    }
  }

  private async logCriticalFailure(
    event: Stripe.Event,
    originalError: string,
    dlqError: any
  ): Promise<void> {
    
    // Log to external monitoring service as last resort
    try {
      await monitoringService.logCritical({
        message: 'Webhook processing completely failed',
        eventId: event.id,
        eventType: event.type,
        originalError,
        dlqError: dlqError instanceof Error ? dlqError.message : 'DLQ failure',
        timestamp: new Date().toISOString()
      })
    } catch (monitoringError) {
      console.error('❌ Even critical logging failed:', monitoringError)
    }
  }
}
```

## Circuit Breaker Pattern

### Webhook Circuit Breaker

```typescript
// lib/webhook-circuit-breaker.ts
export class WebhookCircuitBreaker {
  private failureCount = 0
  private lastFailureTime = 0
  private state: 'closed' | 'open' | 'half-open' = 'closed'
  
  private readonly failureThreshold = 5
  private readonly timeoutMs = 60000 // 1 minute
  private readonly halfOpenMaxCalls = 3

  /**
   * Execute operation with circuit breaker protection
   */
  public async execute<T>(
    operation: () => Promise<T>,
    eventId: string
  ): Promise<{ success: boolean; result?: T; error?: string }> {
    
    if (this.state === 'open') {
      if (Date.now() - this.lastFailureTime > this.timeoutMs) {
        console.log(`🔄 Circuit breaker transitioning to half-open for event ${eventId}`)
        this.state = 'half-open'
        this.failureCount = 0
      } else {
        console.log(`🚫 Circuit breaker open, rejecting event ${eventId}`)
        return { 
          success: false, 
          error: 'Circuit breaker open - webhook processing temporarily disabled' 
        }
      }
    }

    try {
      const result = await operation()
      
      // Success - reset failure count
      if (this.state === 'half-open') {
        console.log(`✅ Circuit breaker closing after successful operation`)
        this.state = 'closed'
      }
      
      this.failureCount = 0
      return { success: true, result }

    } catch (error) {
      this.failureCount++
      this.lastFailureTime = Date.now()

      console.log(`❌ Circuit breaker failure ${this.failureCount}/${this.failureThreshold}`)

      if (this.failureCount >= this.failureThreshold) {
        console.log(`🚫 Circuit breaker opening due to failure threshold`)
        this.state = 'open'
        
        // Send circuit breaker alert
        await this.sendCircuitBreakerAlert(eventId, error)
      }

      return { 
        success: false, 
        error: error instanceof Error ? error.message : 'Operation failed' 
      }
    }
  }

  private async sendCircuitBreakerAlert(eventId: string, error: any): Promise<void> {
    try {
      await monitoringService.alert({
        title: 'Webhook Circuit Breaker Opened',
        description: `Webhook processing circuit breaker opened after ${this.failureCount} failures`,
        severity: 'critical',
        context: {
          eventId,
          lastError: error instanceof Error ? error.message : 'Unknown error',
          failureCount: this.failureCount,
          timestamp: new Date().toISOString()
        }
      })
    } catch (alertError) {
      console.error('❌ Failed to send circuit breaker alert:', alertError)
    }
  }
}
```

## Testing Webhook Reliability

### Reliability Test Suite

```typescript
// __tests__/reliability/webhook-reliability.test.ts
import { WebhookIdempotencyManager, WebhookRetryManager } from '@/lib/webhook-reliability'

describe('Webhook Reliability', () => {
  let idempotencyManager: WebhookIdempotencyManager
  let retryManager: WebhookRetryManager

  beforeAll(() => {
    idempotencyManager = new WebhookIdempotencyManager()
    retryManager = new WebhookRetryManager()
  })

  describe('Idempotency', () => {
    it('should detect duplicate events', async () => {
      const eventId = 'evt_test_duplicate'
      
      // First processing
      await idempotencyManager.recordEventStart(eventId, 'test.event', 'req_1')
      await idempotencyManager.recordEventSuccess(eventId, { processed: true }, 100)

      // Second processing (duplicate)
      const check = await idempotencyManager.checkIdempotency(eventId)
      
      expect(check.alreadyProcessed).toBe(true)
      expect(check.result).toEqual({ processed: true })
    })

    it('should handle concurrent processing attempts', async () => {
      const eventId = 'evt_test_concurrent'
      
      // Simulate concurrent processing
      const promises = [
        idempotencyManager.recordEventStart(eventId, 'test.event', 'req_1'),
        idempotencyManager.recordEventStart(eventId, 'test.event', 'req_2')
      ]

      const results = await Promise.allSettled(promises)
      
      // One should succeed, one should fail due to duplicate
      const successes = results.filter(r => r.status === 'fulfilled').length
      const failures = results.filter(r => r.status === 'rejected').length
      
      expect(successes).toBe(1)
      expect(failures).toBe(1)
    })
  })

  describe('Retry Logic', () => {
    it('should retry failed operations', async () => {
      let attempts = 0
      
      const flakyProcessor = async () => {
        attempts++
        if (attempts < 3) {
          throw new Error('Temporary failure')
        }
        return { success: true, attempts }
      }

      const result = await retryManager.processWithRetry(
        { id: 'evt_test_retry' } as Stripe.Event,
        flakyProcessor
      )

      expect(result.success).toBe(true)
      expect(result.attempts).toBe(3)
      expect(result.result?.attempts).toBe(3)
    })

    it('should not retry non-retryable errors', async () => {
      const nonRetryableProcessor = async () => {
        throw new Error('Invalid data format') // Non-retryable
      }

      const result = await retryManager.processWithRetry(
        { id: 'evt_test_nonretryable' } as Stripe.Event,
        nonRetryableProcessor
      )

      expect(result.success).toBe(false)
      expect(result.attempts).toBe(1) // Should not retry
    })

    it('should respect maximum retry attempts', async () => {
      const alwaysFailProcessor = async () => {
        throw new Error('Network timeout') // Retryable but always fails
      }

      const result = await retryManager.processWithRetry(
        { id: 'evt_test_maxretries' } as Stripe.Event,
        alwaysFailProcessor
      )

      expect(result.success).toBe(false)
      expect(result.attempts).toBe(5) // Max retries
    })
  })

  describe('Circuit Breaker', () => {
    it('should open circuit after failure threshold', async () => {
      const circuitBreaker = new WebhookCircuitBreaker()
      
      const failingOperation = async () => {
        throw new Error('Service unavailable')
      }

      // Trigger failures to open circuit
      for (let i = 0; i < 5; i++) {
        await circuitBreaker.execute(failingOperation, `evt_test_${i}`)
      }

      // Next call should be rejected by open circuit
      const result = await circuitBreaker.execute(failingOperation, 'evt_test_rejected')
      
      expect(result.success).toBe(false)
      expect(result.error).toContain('Circuit breaker open')
    })
  })
})
```

## Webhook Performance Optimization

### Async Processing Pattern

```typescript
// lib/async-webhook-processing.ts
export class AsyncWebhookProcessor {
  /**
   * Process webhook asynchronously for better performance
   */
  public async processAsync(
    event: Stripe.Event,
    requestId: string
  ): Promise<{ queued: boolean; jobId?: string; error?: string }> {
    
    try {
      // Validate event quickly
      const validation = await this.quickValidation(event)
      if (!validation.valid) {
        return { queued: false, error: validation.error }
      }

      // Queue for background processing
      const jobId = await this.queueForProcessing(event, requestId)
      
      console.log(`📋 Event ${event.id} queued for async processing: ${jobId}`)
      return { queued: true, jobId }

    } catch (error) {
      console.error('❌ Async processing queue failed:', error)
      return { 
        queued: false, 
        error: error instanceof Error ? error.message : 'Queue failed' 
      }
    }
  }

  private async quickValidation(event: Stripe.Event): Promise<{
    valid: boolean
    error?: string
  }> {
    
    // Quick checks that don't require database access
    if (!event.id || !event.type) {
      return { valid: false, error: 'Invalid event structure' }
    }

    // Check if event type is supported
    const supportedEvents = [
      'invoice.payment_succeeded',
      'customer.subscription.updated',
      'subscription_schedule.updated'
      // ... other supported events
    ]

    if (!supportedEvents.includes(event.type)) {
      return { valid: false, error: `Unsupported event type: ${event.type}` }
    }

    return { valid: true }
  }

  private async queueForProcessing(
    event: Stripe.Event,
    requestId: string
  ): Promise<string> {
    
    const jobId = crypto.randomUUID()
    
    // Add to processing queue (implementation depends on your queue system)
    await jobQueue.add('process-webhook', {
      eventId: event.id,
      eventType: event.type,
      eventData: event.data,
      requestId,
      jobId,
      queuedAt: new Date().toISOString()
    }, {
      attempts: 3,
      backoff: {
        type: 'exponential',
        delay: 2000,
      },
      removeOnComplete: 10,
      removeOnFail: 50
    })

    return jobId
  }
}
```

## Next Steps

In the next module, we'll cover comprehensive webhook testing strategies and how to test webhook handlers thoroughly.

## Key Takeaways

- Implement robust idempotency to handle duplicate events safely
- Use exponential backoff retry logic for transient failures
- Implement circuit breaker pattern to prevent cascade failures
- Use database transactions for atomic webhook processing
- Set up dead letter queue for permanently failed events
- Monitor webhook reliability metrics and performance
- Implement rate limiting to prevent webhook abuse
- Use async processing for better webhook performance
- Test reliability patterns thoroughly including failure scenarios
- Set up comprehensive alerting for webhook reliability issues
