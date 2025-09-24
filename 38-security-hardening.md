# Security Hardening for Production Billing

## Overview

This module covers security best practices for production Stripe billing systems, including authentication hardening, data protection, webhook security, and compliance considerations. Based on production-tested security patterns, we'll explore comprehensive security measures.

## Authentication Security (Your Actual Patterns)

### API Authentication Hardening

From your actual codebase patterns:

```typescript
// Our recommended authentication pattern
export async function handleSecureAPIRequest(req: Request): Promise<Response> {
  try {
    // Extract user context (implementation varies by framework)
    const user = await getUserFromRequest(req)
    if (!user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // ... rest of API logic
  } catch (error) {
    console.error('Authentication error:', error)
    return new Response(
      JSON.stringify({ error: 'Authentication failed' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
  }
}
```

**Security Enhancements for Production:**

```typescript
// Enhanced authentication with rate limiting
export async function POST(req: Request) {
  try {
    // Rate limiting check
    const clientIP = req.headers.get('x-forwarded-for') || 'unknown'
    await checkRateLimit(clientIP, 'billing_api')

    const supabase = createServerUserClient()
    
    // Enhanced user validation
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError || !user) {
      // Log failed authentication attempts
      await logSecurityEvent('auth_failure', {
        ip: clientIP,
        endpoint: req.url,
        error: authError?.message
      })
      
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    // Validate user is active and not suspended
    const { data: userProfile } = await supabase
      .from('users')
      .select('id, status')
      .eq('id', user.id)
      .single()

    if (!userProfile || userProfile.status === 'suspended') {
      await logSecurityEvent('suspended_user_access', {
        userId: user.id,
        ip: clientIP,
        endpoint: req.url
      })
      
      return new Response(
      JSON.stringify({ error: 'Account suspended' ),
      { status: 403 })
    }

    // ... rest of API logic with user context

  } catch (error) {
    await logSecurityEvent('api_error', {
      ip: clientIP,
      endpoint: req.url,
      error: error.message
    })
    
    return new Response(
      JSON.stringify({ error: 'Internal server error' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

### Rate Limiting Implementation

```typescript
// lib/security/rate-limiting.ts
interface RateLimitConfig {
  windowMs: number
  maxRequests: number
  skipSuccessfulRequests?: boolean
}

const rateLimits: Record<string, RateLimitConfig> = {
  billing_api: {
    windowMs: 15 * 60 * 1000, // 15 minutes
    maxRequests: 100, // 100 requests per 15 minutes
    skipSuccessfulRequests: true
  },
  webhook_endpoint: {
    windowMs: 60 * 1000, // 1 minute
    maxRequests: 1000, // 1000 webhooks per minute
    skipSuccessfulRequests: false
  },
  checkout_creation: {
    windowMs: 60 * 1000, // 1 minute
    maxRequests: 10, // 10 checkouts per minute per IP
    skipSuccessfulRequests: false
  }
}

export async function checkRateLimit(identifier: string, limitType: string): Promise<void> {
  const config = rateLimits[limitType]
  if (!config) return

  const key = `rate_limit:${limitType}:${identifier}`
  const now = Date.now()
  const windowStart = now - config.windowMs

  try {
    // Get recent requests (you'd use Redis in production)
    const { data: recentRequests } = await supabase
      .from('rate_limit_log')
      .select('timestamp')
      .eq('identifier', identifier)
      .eq('limit_type', limitType)
      .gte('timestamp', new Date(windowStart).toISOString())

    if (recentRequests && recentRequests.length >= config.maxRequests) {
      throw new Error(`Rate limit exceeded: ${config.maxRequests} requests per ${config.windowMs}ms`)
    }

    // Log this request
    await supabase
      .from('rate_limit_log')
      .insert({
        identifier,
        limit_type: limitType,
        timestamp: new Date().toISOString()
      })

  } catch (error) {
    if (error.message.includes('Rate limit exceeded')) {
      throw error
    }
    // Don't fail requests for rate limiting errors
    console.error('Rate limiting error:', error)
  }
}
```

## Webhook Security Hardening

### Enhanced Signature Verification

```typescript
// Enhanced webhook security (builds on your patterns)
export async function POST(request: Request) {
  const clientIP = request.headers.get('x-forwarded-for') || 'unknown'
  const userAgent = request.headers.get('user-agent') || 'unknown'
  
  try {
    // Rate limiting for webhooks
    await checkRateLimit(clientIP, 'webhook_endpoint')

    const body = await request.text()
    const signature = request.headers.get('stripe-signature')

    if (!signature) {
      await logSecurityEvent('webhook_missing_signature', {
        ip: clientIP,
        userAgent,
        bodyLength: body.length
      })
      
      return new Response(
      JSON.stringify(
        { error: 'Missing stripe-signature header' },
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Enhanced signature verification
    let event: any
    try {
      event = stripe.webhooks.constructEvent(body, signature, webhookSecret)
    } catch (err) {
      await logSecurityEvent('webhook_invalid_signature', {
        ip: clientIP,
        userAgent,
        signatureHeader: signature.substring(0, 20) + '...', // Partial for debugging
        error: err.message
      })

      console.error('❌ Webhook signature verification failed:', err)
      return new Response(
      JSON.stringify(
        { error: 'Invalid signature' },
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Validate event age (prevent replay attacks)
    const eventAge = Date.now() - (event.created * 1000)
    const maxAge = 5 * 60 * 1000 // 5 minutes
    
    if (eventAge > maxAge) {
      await logSecurityEvent('webhook_stale_event', {
        eventId: event.id,
        eventAge: eventAge,
        maxAge: maxAge
      })
      
      return new Response(
      JSON.stringify(
        { error: 'Event too old' },
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Check for duplicate events (idempotency)
    const { data: existingEvent } = await supabase
      .from('webhook_events')
      .select('event_id')
      .eq('event_id', event.id)
      .single()

    if (existingEvent) {
      console.log(`⚠️  Duplicate webhook event received: ${event.id}`)
      return new Response(
      JSON.stringify({ received: true, duplicate: true })
    }

    // Process the event
    await processWebhookEvent(event)
    
    return new Response(
      JSON.stringify({ received: true })

  } catch (error) {
    await logSecurityEvent('webhook_processing_error', {
      ip: clientIP,
      error: error.message
    })
    
    console.error('Webhook processing error:', error)
    return new Response(
      JSON.stringify(
      { error: 'Webhook processing failed' },
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

### Security Event Logging

```typescript
// lib/security/event-logging.ts
interface SecurityEvent {
  eventType: string
  severity: 'low' | 'medium' | 'high' | 'critical'
  metadata: any
  timestamp: string
  environment: string
}

export async function logSecurityEvent(
  eventType: string, 
  metadata: any = {},
  severity: 'low' | 'medium' | 'high' | 'critical' = 'medium'
) {
  const event: SecurityEvent = {
    eventType,
    severity,
    metadata,
    timestamp: new Date().toISOString(),
    environment: process.env.NODE_ENV || 'unknown'
  }

  try {
    // Log to database
    const supabase = createServerServiceRoleClient()
    await supabase
      .from('security_events')
      .insert({
        event_type: eventType,
        severity,
        metadata,
        timestamp: event.timestamp,
        environment: event.environment
      })

    // Log to console with appropriate level
    const logLevel = severity === 'critical' ? 'error' : 
                   severity === 'high' ? 'warn' : 'log'
    console[logLevel](`🔒 Security Event [${severity.toUpperCase()}]: ${eventType}`, metadata)

    // Send critical events to alerting system
    if (severity === 'critical') {
      await sendCriticalSecurityAlert(event)
    }

  } catch (error) {
    console.error('Failed to log security event:', error)
  }
}

async function sendCriticalSecurityAlert(event: SecurityEvent) {
  try {
    // Send to alerting system (PagerDuty, Slack, etc.)
    console.log('🚨 CRITICAL SECURITY EVENT:', event)
    
    // Example: Send to Slack webhook
    if (process.env.SLACK_SECURITY_WEBHOOK) {
      await fetch(process.env.SLACK_SECURITY_WEBHOOK, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          text: `🚨 CRITICAL SECURITY EVENT: ${event.eventType}`,
          attachments: [{
            color: 'danger',
            fields: [
              { title: 'Event Type', value: event.eventType, short: true },
              { title: 'Environment', value: event.environment, short: true },
              { title: 'Timestamp', value: event.timestamp, short: false },
              { title: 'Metadata', value: JSON.stringify(event.metadata, null, 2), short: false }
            ]
          }]
        })
      })
    }
  } catch (error) {
    console.error('Failed to send critical security alert:', error)
  }
}
```

## Data Protection and Privacy

### PII Data Handling

```typescript
// Secure handling of personally identifiable information
export const PIIProtection = {
  // Mask sensitive data in logs
  maskSensitiveData(data: any): any {
    const masked = { ...data }
    
    // Mask email addresses
    if (masked.email) {
      const [local, domain] = masked.email.split('@')
      masked.email = `${local.substring(0, 2)}***@${domain}`
    }

    // Mask payment method details
    if (masked.last4) {
      masked.last4 = '****'
    }

    // Remove sensitive fields entirely
    delete masked.stripe_customer_id
    delete masked.payment_method_id
    
    return masked
  },

  // Validate data access permissions
  async validateDataAccess(userId: string, requestedUserId: string): Promise<boolean> {
    // Users can only access their own data
    if (userId !== requestedUserId) {
      await logSecurityEvent('unauthorized_data_access', {
        userId,
        requestedUserId
      }, 'high')
      
      return false
    }

    return true
  },

  // Audit data access
  async auditDataAccess(userId: string, operation: string, resourceId: string) {
    const supabase = createServerServiceRoleClient()
    
    await supabase
      .from('data_access_log')
      .insert({
        user_id: userId,
        operation,
        resource_id: resourceId,
        timestamp: new Date().toISOString(),
        ip_address: 'unknown', // Would get from request context
        user_agent: 'unknown'  // Would get from request context
      })
  }
}
```

### Data Encryption

```typescript
// Encryption for sensitive data storage
export const DataEncryption = {
  // Encrypt sensitive metadata before storing
  async encryptMetadata(metadata: any): Promise<string> {
    if (process.env.NODE_ENV !== 'production') {
      // Skip encryption in development for easier debugging
      return JSON.stringify(metadata)
    }

    const crypto = require('crypto')
    const algorithm = 'aes-256-gcm'
    const key = Buffer.from(process.env.ENCRYPTION_KEY!, 'hex')
    const iv = crypto.randomBytes(16)

    const cipher = crypto.createCipher(algorithm, key, iv)
    let encrypted = cipher.update(JSON.stringify(metadata), 'utf8', 'hex')
    encrypted += cipher.final('hex')

    const authTag = cipher.getAuthTag()

    return JSON.stringify({
      encrypted,
      iv: iv.toString('hex'),
      authTag: authTag.toString('hex')
    })
  },

  // Decrypt sensitive metadata
  async decryptMetadata(encryptedData: string): Promise<any> {
    if (process.env.NODE_ENV !== 'production') {
      // Data not encrypted in development
      return JSON.parse(encryptedData)
    }

    try {
      const { encrypted, iv, authTag } = JSON.parse(encryptedData)
      
      const crypto = require('crypto')
      const algorithm = 'aes-256-gcm'
      const key = Buffer.from(process.env.ENCRYPTION_KEY!, 'hex')

      const decipher = crypto.createDecipher(algorithm, key, Buffer.from(iv, 'hex'))
      decipher.setAuthTag(Buffer.from(authTag, 'hex'))

      let decrypted = decipher.update(encrypted, 'hex', 'utf8')
      decrypted += decipher.final('utf8')

      return JSON.parse(decrypted)

    } catch (error) {
      console.error('Decryption failed:', error)
      throw new Error('Failed to decrypt metadata')
    }
  }
}
```

## Webhook Security Hardening

### Advanced Webhook Validation

```typescript
// Enhanced webhook security (builds on your patterns)
export async function validateWebhookSecurity(request: Request): Promise<{
  valid: boolean
  event?: any
  error?: string
}> {
  
  const clientIP = request.headers.get('x-forwarded-for') || 'unknown'
  const userAgent = request.headers.get('user-agent') || 'unknown'

  try {
    // 1. Validate request origin
    if (!isValidStripeIP(clientIP)) {
      await logSecurityEvent('webhook_invalid_origin', {
        ip: clientIP,
        userAgent
      }, 'high')
      
      return { valid: false, error: 'Invalid request origin' }
    }

    // 2. Validate user agent
    if (!userAgent.includes('Stripe')) {
      await logSecurityEvent('webhook_invalid_user_agent', {
        ip: clientIP,
        userAgent
      }, 'medium')
    }

    // 3. Validate content type
    const contentType = request.headers.get('content-type')
    if (contentType !== 'application/json') {
      return { valid: false, error: 'Invalid content type' }
    }

    // 4. Validate signature (your existing pattern)
    const body = await request.text()
    const signature = request.headers.get('stripe-signature')

    if (!signature) {
      return { valid: false, error: 'Missing signature' }
    }

    const event = stripe.webhooks.constructEvent(body, signature, webhookSecret)

    // 5. Validate event structure
    if (!event.id || !event.type || !event.data) {
      return { valid: false, error: 'Invalid event structure' }
    }

    // 6. Check event age (prevent replay attacks)
    const eventAge = Date.now() - (event.created * 1000)
    const maxAge = 5 * 60 * 1000 // 5 minutes
    
    if (eventAge > maxAge) {
      await logSecurityEvent('webhook_stale_event', {
        eventId: event.id,
        eventAge,
        maxAge
      }, 'medium')
      
      return { valid: false, error: 'Event too old' }
    }

    return { valid: true, event }

  } catch (error) {
    await logSecurityEvent('webhook_validation_error', {
      ip: clientIP,
      error: error.message
    }, 'high')

    return { valid: false, error: error.message }
  }
}

function isValidStripeIP(ip: string): boolean {
  // Stripe's webhook IP ranges (check Stripe docs for current ranges)
  const stripeIPRanges = [
    '3.18.12.63',
    '3.130.192.231',
    '13.235.14.237',
    '13.235.122.149',
    '18.211.135.69',
    '35.154.171.200',
    '52.15.183.38',
    '54.88.130.119',
    '54.88.130.237',
    '54.187.174.169',
    '54.187.205.235',
    '54.187.216.72'
  ]

  // In production, implement proper CIDR range checking
  return process.env.NODE_ENV !== 'production' || stripeIPRanges.includes(ip)
}
```

## Environment Variable Security

### Secure Configuration Management

```typescript
// lib/config/secure-config.ts
export class SecureConfig {
  private static instance: SecureConfig
  private config: Map<string, string> = new Map()

  static getInstance(): SecureConfig {
    if (!SecureConfig.instance) {
      SecureConfig.instance = new SecureConfig()
    }
    return SecureConfig.instance
  }

  private constructor() {
    this.loadSecureConfig()
  }

  private loadSecureConfig() {
    // Validate required environment variables
    const requiredVars = [
      'STRIPE_SECRET_KEY',
      'STRIPE_WEBHOOK_SECRET',
      'SUPABASE_SERVICE_ROLE_KEY'
    ]

    const missing = requiredVars.filter(varName => !process.env[varName])
    
    if (missing.length > 0) {
      throw new Error(`Missing required environment variables: ${missing.join(', ')}`)
    }

    // Validate key formats
    this.validateKeyFormats()

    // Store in secure map
    requiredVars.forEach(varName => {
      this.config.set(varName, process.env[varName]!)
    })

    console.log('✅ Secure configuration loaded')
  }

  private validateKeyFormats() {
    const stripeKey = process.env.STRIPE_SECRET_KEY!
    
    if (!stripeKey.startsWith('sk_test_') && !stripeKey.startsWith('sk_live_')) {
      throw new Error('Invalid STRIPE_SECRET_KEY format')
    }

    const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET!
    if (!webhookSecret.startsWith('whsec_')) {
      throw new Error('Invalid STRIPE_WEBHOOK_SECRET format')
    }

    // Validate key lengths
    if (stripeKey.length < 50) {
      throw new Error('STRIPE_SECRET_KEY appears to be invalid (too short)')
    }

    if (webhookSecret.length < 30) {
      throw new Error('STRIPE_WEBHOOK_SECRET appears to be invalid (too short)')
    }
  }

  getStripeSecretKey(): string {
    return this.config.get('STRIPE_SECRET_KEY')!
  }

  getWebhookSecret(): string {
    return this.config.get('STRIPE_WEBHOOK_SECRET')!
  }

  // Mask sensitive values for logging
  getMaskedConfig(): Record<string, string> {
    const masked: Record<string, string> = {}
    
    for (const [key, value] of this.config.entries()) {
      if (key.includes('SECRET') || key.includes('KEY')) {
        masked[key] = value.substring(0, 8) + '***'
      } else {
        masked[key] = value
      }
    }

    return masked
  }
}
```

## Database Security Hardening

### Enhanced RLS Policies

```sql
-- Enhanced Row Level Security policies
-- Users table - enhanced with audit logging
CREATE OR REPLACE FUNCTION audit_user_access()
RETURNS TRIGGER AS $$
BEGIN
  -- Log data access for audit purposes
  INSERT INTO data_access_log (
    user_id,
    table_name,
    operation,
    accessed_at
  ) VALUES (
    auth.uid(),
    TG_TABLE_NAME,
    TG_OP,
    NOW()
  );
  
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Apply audit trigger to sensitive tables
CREATE TRIGGER audit_users_access
  AFTER SELECT OR UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION audit_user_access();

CREATE TRIGGER audit_subscriptions_access
  AFTER SELECT OR UPDATE ON subscriptions
  FOR EACH ROW EXECUTE FUNCTION audit_user_access();
```

### Database Connection Security

```typescript
// Enhanced database security
export function createSecureSupabaseClient() {
  const config = SecureConfig.getInstance()
  
  // Use connection pooling and SSL
  const supabase = createClient(
    process.env.SUPABASE_URL!,
    config.get('SUPABASE_SERVICE_ROLE_KEY')!,
    {
      db: {
        schema: 'public'
      },
      auth: {
        autoRefreshToken: false,
        persistSession: false
      },
      global: {
        headers: {
          'x-application-name': 'billing-service',
          'x-environment': process.env.NODE_ENV
        }
      }
    }
  )

  return supabase
}
```

## API Security Hardening

### Input Validation and Sanitization

```typescript
// Enhanced input validation for your APIs
export const InputValidation = {
  validateUpgradeRequest(body: any): { valid: boolean; errors: string[] } {
    const errors: string[] = []

    // Validate required fields
    if (!body.newPlanId || typeof body.newPlanId !== 'string') {
      errors.push('newPlanId is required and must be a string')
    }

    if (body.billingInterval && !['month', 'year'].includes(body.billingInterval)) {
      errors.push('billingInterval must be "month" or "year"')
    }

    // Validate plan ID format
    if (body.newPlanId && !/^[a-z]+$/.test(body.newPlanId)) {
      errors.push('newPlanId contains invalid characters')
    }

    // Validate price ID format if provided
    if (body.newPriceId && !body.newPriceId.startsWith('price_')) {
      errors.push('newPriceId must start with "price_"')
    }

    // Check for SQL injection attempts
    const sqlPatterns = ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'DROP', '--', ';']
    const bodyString = JSON.stringify(body).toLowerCase()
    
    for (const pattern of sqlPatterns) {
      if (bodyString.includes(pattern.toLowerCase())) {
        errors.push('Request contains potentially malicious content')
        
        // Log security incident
        logSecurityEvent('potential_sql_injection', {
          body: body,
          detectedPattern: pattern
        }, 'critical')
        
        break
      }
    }

    return {
      valid: errors.length === 0,
      errors
    }
  },

  sanitizeInput(input: any): any {
    if (typeof input === 'string') {
      // Remove potentially dangerous characters
      return input.replace(/[<>\"'%;()&+]/g, '')
    }

    if (typeof input === 'object' && input !== null) {
      const sanitized: any = {}
      for (const [key, value] of Object.entries(input)) {
        sanitized[key] = this.sanitizeInput(value)
      }
      return sanitized
    }

    return input
  }
}
```

## Security Headers and CORS

### Security Headers Configuration

```typescript
// middleware.ts - Enhanced security headers
import { Response } from 'next/server'
import type { Request } from 'next/server'

export function middleware(request: Request) {
  const response = Response.next()

  // Security headers
  response.headers.set('X-Frame-Options', 'DENY')
  response.headers.set('X-Content-Type-Options', 'nosniff')
  response.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin')
  response.headers.set('X-XSS-Protection', '1; mode=block')
  
  // Content Security Policy
  response.headers.set('Content-Security-Policy', [
    "default-src 'self'",
    "script-src 'self' 'unsafe-inline' js.stripe.com",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: https:",
    "connect-src 'self' api.stripe.com",
    "frame-src js.stripe.com checkout.stripe.com billing.stripe.com",
    "form-action 'self' checkout.stripe.com"
  ].join('; '))

  // HSTS for HTTPS enforcement
  if (process.env.NODE_ENV === 'production') {
    response.headers.set('Strict-Transport-Security', 'max-age=31536000; includeSubDomains')
  }

  return response
}

export const config = {
  matcher: [
    '/((?!api/webhooks|_next/static|_next/image|favicon.ico).*)',
  ],
}
```

### CORS Configuration for APIs

```typescript
// Enhanced CORS for billing APIs
export function configureCORS(request: Request, response: Response) {
  const origin = request.headers.get('origin')
  const allowedOrigins = [
    process.env.APP_URL,
    'https://checkout.stripe.com',
    'https://billing.stripe.com'
  ].filter(Boolean)

  if (origin && allowedOrigins.includes(origin)) {
    response.headers.set('Access-Control-Allow-Origin', origin)
  }

  response.headers.set('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
  response.headers.set('Access-Control-Allow-Headers', 'Content-Type, Authorization, stripe-signature')
  response.headers.set('Access-Control-Max-Age', '86400') // 24 hours

  return response
}
```

## Security Monitoring and Alerting

### Security Event Dashboard

```typescript
// Security monitoring dashboard
export const SecurityDashboard = {
  async getSecurityMetrics(timeframe: '24h' | '7d' | '30d' = '24h') {
    const hoursBack = timeframe === '24h' ? 24 : timeframe === '7d' ? 168 : 720
    const since = new Date(Date.now() - hoursBack * 60 * 60 * 1000)

    const supabase = createServerServiceRoleClient()

    // Security events
    const { data: securityEvents } = await supabase
      .from('security_events')
      .select('event_type, severity, timestamp')
      .gte('timestamp', since.toISOString())

    // Failed authentication attempts
    const { data: authFailures } = await supabase
      .from('security_events')
      .select('metadata, timestamp')
      .eq('event_type', 'auth_failure')
      .gte('timestamp', since.toISOString())

    // Webhook security events
    const { data: webhookSecurity } = await supabase
      .from('security_events')
      .select('event_type, timestamp')
      .like('event_type', 'webhook_%')
      .gte('timestamp', since.toISOString())

    return {
      timeframe,
      summary: {
        totalSecurityEvents: securityEvents?.length || 0,
        criticalEvents: securityEvents?.filter(e => e.severity === 'critical').length || 0,
        authFailures: authFailures?.length || 0,
        webhookSecurityEvents: webhookSecurity?.length || 0
      },
      eventsByType: securityEvents?.reduce((acc, event) => {
        acc[event.event_type] = (acc[event.event_type] || 0) + 1
        return acc
      }, {} as Record<string, number>) || {},
      eventsBySeverity: securityEvents?.reduce((acc, event) => {
        acc[event.severity] = (acc[event.severity] || 0) + 1
        return acc
      }, {} as Record<string, number>) || {}
    }
  },

  async getTopSecurityThreats(limit: number = 10) {
    const supabase = createServerServiceRoleClient()
    
    const { data: threats } = await supabase
      .from('security_events')
      .select('event_type, metadata, timestamp')
      .eq('severity', 'critical')
      .order('timestamp', { ascending: false })
      .limit(limit)

    return threats || []
  }
}
```

## Security Testing

### Security Test Suite

```typescript
// Security-focused tests
describe('Security Hardening', () => {
  describe('Authentication Security', () => {
    it('should reject requests without authentication', async () => {
      const response = await fetch('/api/billing/upgrade', {
        method: 'POST',
        body: JSON.stringify({ newPlanId: 'pro' })
      })

      expect(response.status).toBe(401)
    })

    it('should reject requests with invalid tokens', async () => {
      const response = await fetch('/api/billing/upgrade', {
        method: 'POST',
        headers: {
          'Authorization': 'Bearer invalid_token'
        },
        body: JSON.stringify({ newPlanId: 'pro' })
      })

      expect(response.status).toBe(401)
    })
  })

  describe('Input Validation', () => {
    it('should reject malicious input', async () => {
      const response = await fetch('/api/billing/upgrade', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${validToken}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          newPlanId: "'; DROP TABLE subscriptions; --"
        })
      })

      expect(response.status).toBe(400)
      
      const data = await response.json()
      expect(data.error).toContain('malicious content')
    })
  })

  describe('Webhook Security', () => {
    it('should reject webhooks with invalid signatures', async () => {
      const response = await fetch('/api/webhooks/stripe', {
        method: 'POST',
        headers: {
          'stripe-signature': 'invalid_signature',
          'content-type': 'application/json'
        },
        body: JSON.stringify({ type: 'test.event' })
      })

      expect(response.status).toBe(400)
    })

    it('should reject old webhook events', async () => {
      const oldTimestamp = Math.floor((Date.now() - 10 * 60 * 1000) / 1000) // 10 minutes ago
      const oldEvent = {
        id: 'evt_old_test',
        type: 'test.event',
        created: oldTimestamp,
        data: { object: {} }
      }

      const body = JSON.stringify(oldEvent)
      const signature = createTestWebhookSignature(body, oldTimestamp)

      const response = await fetch('/api/webhooks/stripe', {
        method: 'POST',
        headers: {
          'stripe-signature': signature,
          'content-type': 'application/json'
        },
        body: body
      })

      expect(response.status).toBe(400)
    })
  })
})
```

## Alternative: Advanced Security Monitoring

For enterprise-level security monitoring:

### Security Information and Event Management (SIEM)

```typescript
// lib/security/siem-integration.ts (Alternative approach)
export class SIEMIntegration {
  async sendSecurityEvent(event: SecurityEvent) {
    try {
      // Send to SIEM system (Splunk, ELK, etc.)
      await fetch(process.env.SIEM_WEBHOOK_URL!, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${process.env.SIEM_API_KEY}`
        },
        body: JSON.stringify({
          timestamp: event.timestamp,
          source: 'billing-system',
          severity: event.severity,
          event_type: event.eventType,
          metadata: event.metadata,
          environment: process.env.NODE_ENV
        })
      })

      console.log(`📤 Security event sent to SIEM: ${event.eventType}`)

    } catch (error) {
      console.error('Failed to send security event to SIEM:', error)
    }
  }

  async querySecurityEvents(query: {
    eventType?: string
    severity?: string
    timeRange?: { start: Date; end: Date }
  }) {
    // Query SIEM system for security events
    // Implementation depends on your SIEM system
  }
}
```

## Next Steps

In the next module, we'll cover multi-tenant billing architectures and advanced patterns.

## Key Takeaways

- **Implement comprehensive authentication** with rate limiting and validation
- **Harden webhook security** with IP validation, signature verification, and replay protection
- **Use structured security logging** for audit trails and incident response
- **Validate all inputs** and sanitize data to prevent injection attacks
- **Set up security monitoring** with appropriate alerting thresholds
- **Encrypt sensitive data** in production environments
- **Configure security headers** to protect against common web vulnerabilities
- **Test security measures** with dedicated security test suites
- **Monitor security events** and respond to threats proactively
- **Maintain security configuration** with proper secret management
