# Plan Validation and Business Rules

## Overview

This module covers implementing robust plan validation logic and business rules for plan changes. We'll explore how to validate plan transitions, enforce business constraints, and provide clear feedback when plan changes aren't allowed.

## Validation Architecture

Your plan validation system should enforce business rules at multiple layers:

```
Frontend Validation → API Validation → Database Constraints → Business Logic
```

### Core Validation Components

1. **Plan Transition Rules**: Define allowed upgrade/downgrade paths
2. **Business Rule Engine**: Enforce complex business constraints
3. **User Context Validation**: Check user eligibility for plan changes
4. **Feature Compatibility**: Ensure user's usage fits new plan limits
5. **Payment Method Validation**: Verify payment methods for paid plans

## Plan Transition Validation

### Core Validation Functions

```typescript
// lib/plan-validation.ts
import { getPlanConfig, getAllPlans } from '@/lib/plan-config'

export interface ValidationResult {
  valid: boolean
  error?: string
  warnings?: string[]
  requirements?: string[]
}

export function validatePlanTransition(
  fromPlanId: string,
  toPlanId: string,
  userId?: string
): ValidationResult {
  // Basic plan existence check
  const fromPlan = getPlanConfig(fromPlanId)
  const toPlan = getPlanConfig(toPlanId)

  if (!fromPlan) {
    return { valid: false, error: `Invalid source plan: ${fromPlanId}` }
  }

  if (!toPlan) {
    return { valid: false, error: `Invalid target plan: ${toPlanId}` }
  }

  // Same plan check
  if (fromPlanId === toPlanId) {
    return { valid: false, error: 'Cannot change to the same plan' }
  }

  // Check if transition is explicitly allowed
  const isUpgrade = fromPlan.upgradePlans.includes(toPlanId)
  const isDowngrade = fromPlan.downgradePlans.includes(toPlanId)

  if (!isUpgrade && !isDowngrade) {
    return {
      valid: false,
      error: `Plan change from ${fromPlan.name} to ${toPlan.name} is not allowed`,
      requirements: [
        `Allowed upgrades: ${fromPlan.upgradePlans.join(', ') || 'None'}`,
        `Allowed downgrades: ${fromPlan.downgradePlans.join(', ') || 'None'}`
      ]
    }
  }

  // Additional validation for downgrades
  if (isDowngrade) {
    const warnings = []
    
    // Feature reduction warnings
    if (toPlan.includedComputeMinutes < fromPlan.includedComputeMinutes) {
      warnings.push(`Compute minutes will reduce from ${fromPlan.includedComputeMinutes} to ${toPlan.includedComputeMinutes}`)
    }
    
    if (toPlan.concurrencyLimit < fromPlan.concurrencyLimit) {
      warnings.push(`Concurrent jobs will reduce from ${fromPlan.concurrencyLimit} to ${toPlan.concurrencyLimit}`)
    }
    
    if (fromPlan.allowOverages && !toPlan.allowOverages) {
      warnings.push('Overages will no longer be available - jobs will queue when limits are reached')
    }

    return { valid: true, warnings }
  }

  // Upgrade validation passed
  return { valid: true }
}
```

### Billing Interval Validation

```typescript
export function validateBillingIntervalChange(
  planId: string,
  fromInterval: 'month' | 'year',
  toInterval: 'month' | 'year'
): ValidationResult {
  const plan = getPlanConfig(planId)
  
  if (!plan) {
    return { valid: false, error: 'Invalid plan' }
  }

  if (fromInterval === toInterval) {
    return { valid: false, error: 'Cannot change to the same billing interval' }
  }

  // Check if target interval is available for this plan
  const availableIntervals = []
  if (plan.monthly) availableIntervals.push('month')
  if (plan.annual) availableIntervals.push('year')

  if (!availableIntervals.includes(toInterval)) {
    return {
      valid: false,
      error: `${toInterval === 'month' ? 'Monthly' : 'Annual'} billing not available for ${plan.name}`,
      requirements: [`Available intervals: ${availableIntervals.join(', ')}`]
    }
  }

  const warnings = []

  // Add warnings for interval changes
  if (toInterval === 'year') {
    warnings.push('You will be charged upfront for the full year')
    warnings.push('Compute minutes will reset monthly, not annually')
  } else {
    warnings.push('You will lose annual billing discount')
    warnings.push('Next billing will be monthly')
  }

  return { valid: true, warnings }
}
```

## User Context Validation

### Usage-Based Validation

```typescript
// lib/usage-validation.ts
export async function validateUserUsageForPlan(
  userId: string,
  targetPlanId: string
): Promise<ValidationResult> {
  try {
    const targetPlan = getPlanConfig(targetPlanId)
    if (!targetPlan) {
      return { valid: false, error: 'Invalid plan' }
    }

    // Get current period usage
    const currentUsage = await getCurrentPeriodUsage(userId)
    if (!currentUsage) {
      return { valid: true } // No usage data, allow change
    }

    const warnings = []
    const requirements = []

    // Check compute minutes usage
    if (currentUsage.computeMinutes > targetPlan.includedComputeMinutes) {
      if (targetPlan.allowOverages) {
        const overageMinutes = currentUsage.computeMinutes - targetPlan.includedComputeMinutes
        const overageCost = (overageMinutes * (targetPlan.overagePricePerMinuteCents || 0)) / 100
        warnings.push(
          `You've used ${currentUsage.computeMinutes} minutes this period. ` +
          `${targetPlan.name} includes ${targetPlan.includedComputeMinutes} minutes. ` +
          `Overage cost would be $${overageCost.toFixed(2)}`
        )
      } else {
        return {
          valid: false,
          error: `You've used ${currentUsage.computeMinutes} minutes this period, but ${targetPlan.name} only includes ${targetPlan.includedComputeMinutes} minutes and doesn't allow overages`,
          requirements: [
            'Wait until next billing period when usage resets',
            'Choose a plan with higher limits',
            'Reduce your current usage'
          ]
        }
      }
    }

    // Check concurrent jobs
    if (currentUsage.peakConcurrentJobs > targetPlan.concurrencyLimit) {
      warnings.push(
        `Your peak concurrent jobs (${currentUsage.peakConcurrentJobs}) exceeds ` +
        `${targetPlan.name} limit (${targetPlan.concurrencyLimit}). ` +
        `Future jobs may queue during peak usage.`
      )
    }

    return { valid: true, warnings, requirements }

  } catch (error) {
    console.error('Usage validation error:', error)
    return { 
      valid: false, 
      error: 'Unable to validate usage. Please try again.' 
    }
  }
}

async function getCurrentPeriodUsage(userId: string) {
  const supabase = createServerUserClient()
  
  // Get current subscription to determine billing period
  const { data: subscription } = await supabase
    .from('subscriptions')
    .select('current_period_start, current_period_end')
    .eq('user_id', userId)
    .single()

  if (!subscription) return null

  // Get usage summary for current period
  const { data: usage } = await supabase
    .rpc('get_usage_summary', {
      user_uuid: userId,
      period_start: subscription.current_period_start,
      period_end: subscription.current_period_end
    })

  if (!usage || usage.length === 0) return null

  // Calculate total usage
  const computeMinutes = usage
    .filter((u: any) => u.feature_name === 'compute_minutes')
    .reduce((sum: number, u: any) => sum + u.total_usage, 0)

  const peakConcurrentJobs = usage
    .filter((u: any) => u.feature_name === 'concurrent_jobs')
    .reduce((max: number, u: any) => Math.max(max, u.total_usage), 0)

  return {
    computeMinutes,
    peakConcurrentJobs
  }
}
```

### Payment Method Validation

```typescript
// lib/payment-validation.ts
export async function validatePaymentMethodForPlan(
  userId: string,
  targetPlanId: string
): Promise<ValidationResult> {
  const targetPlan = getPlanConfig(targetPlanId)
  if (!targetPlan) {
    return { valid: false, error: 'Invalid plan' }
  }

  // Free plan doesn't require payment method
  if (targetPlan.isFree) {
    return { valid: true }
  }

  try {
    // Check if user has valid payment method
    const subscription = await getSubscriptionDetails(userId)
    if (!subscription?.stripeCustomerId) {
      return {
        valid: false,
        error: 'No payment method on file',
        requirements: ['Add a payment method to upgrade to paid plans']
      }
    }

    // Check payment method with Stripe
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    const customer = await stripe.customers.retrieve(subscription.stripeCustomerId)
    if (typeof customer === 'string' || customer.deleted) {
      return {
        valid: false,
        error: 'Customer not found in Stripe',
        requirements: ['Contact support to resolve payment method issues']
      }
    }

    // Check for valid payment methods
    const paymentMethods = await stripe.paymentMethods.list({
      customer: customer.id,
      type: 'card'
    })

    if (paymentMethods.data.length === 0) {
      return {
        valid: false,
        error: 'No valid payment method found',
        requirements: ['Add a credit card to upgrade to paid plans']
      }
    }

    // Check if default payment method is valid
    const defaultPaymentMethod = customer.invoice_settings?.default_payment_method
    if (!defaultPaymentMethod) {
      return {
        valid: true,
        warnings: ['No default payment method set. First available card will be used.']
      }
    }

    return { valid: true }

  } catch (error) {
    console.error('Payment validation error:', error)
    return {
      valid: false,
      error: 'Unable to validate payment method. Please try again.'
    }
  }
}
```

## Business Rules Engine

### Complex Validation Rules

```typescript
// lib/business-rules.ts
export interface BusinessRule {
  name: string
  description: string
  validate: (context: ValidationContext) => ValidationResult
}

export interface ValidationContext {
  userId: string
  fromPlanId: string
  toPlanId: string
  billingInterval?: 'month' | 'year'
  userProfile?: any
  subscription?: any
  usage?: any
}

export const businessRules: BusinessRule[] = [
  {
    name: 'trial_to_paid_validation',
    description: 'Validate trial to paid plan transitions',
    validate: (context) => {
      // Custom logic for trial users
      if (context.subscription?.status === 'trialing') {
        const toPlan = getPlanConfig(context.toPlanId)
        if (toPlan && !toPlan.isFree) {
          return {
            valid: true,
            warnings: ['Trial will end immediately when upgrading to a paid plan']
          }
        }
      }
      return { valid: true }
    }
  },

  {
    name: 'enterprise_contact_required',
    description: 'Enterprise plans require sales contact',
    validate: (context) => {
      if (context.toPlanId === 'enterprise') {
        return {
          valid: false,
          error: 'Enterprise plans require sales consultation',
          requirements: ['Contact sales@company.com for enterprise pricing']
        }
      }
      return { valid: true }
    }
  },

  {
    name: 'downgrade_data_retention',
    description: 'Warn about data retention on downgrades',
    validate: (context) => {
      const fromPlan = getPlanConfig(context.fromPlanId)
      const toPlan = getPlanConfig(context.toPlanId)
      
      if (fromPlan && toPlan && 
          fromPlan.includedComputeMinutes > toPlan.includedComputeMinutes) {
        return {
          valid: true,
          warnings: [
            'Job history older than 90 days may be archived on lower plans',
            'Export important data before downgrading if needed'
          ]
        }
      }
      return { valid: true }
    }
  },

  {
    name: 'geographic_restrictions',
    description: 'Check geographic restrictions for certain plans',
    validate: (context) => {
      // Example: Some plans might not be available in certain regions
      if (context.userProfile?.country === 'restricted_country' && 
          context.toPlanId === 'enterprise') {
        return {
          valid: false,
          error: 'This plan is not available in your region',
          requirements: ['Contact support for available options in your area']
        }
      }
      return { valid: true }
    }
  }
]

export async function validateBusinessRules(
  context: ValidationContext
): Promise<ValidationResult> {
  const allWarnings: string[] = []
  const allRequirements: string[] = []

  for (const rule of businessRules) {
    try {
      const result = rule.validate(context)
      
      if (!result.valid) {
        return {
          valid: false,
          error: result.error,
          requirements: result.requirements
        }
      }

      if (result.warnings) {
        allWarnings.push(...result.warnings)
      }

      if (result.requirements) {
        allRequirements.push(...result.requirements)
      }
    } catch (error) {
      console.error(`Business rule ${rule.name} failed:`, error)
      // Continue with other rules
    }
  }

  return {
    valid: true,
    warnings: allWarnings.length > 0 ? allWarnings : undefined,
    requirements: allRequirements.length > 0 ? allRequirements : undefined
  }
}
```

## Comprehensive Validation API

### Validation Endpoint

```typescript
// app/api/plans/validate-change/route.ts
// Framework-agnostic imports
import { createServerUserClient } from '@/lib/supabase-clients'
import { 
  validatePlanTransition,
  validateBillingIntervalChange,
  validateUserUsageForPlan,
  validatePaymentMethodForPlan,
  validateBusinessRules
} from '@/lib/plan-validation'

export async function POST(request: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    const { 
      fromPlanId, 
      toPlanId, 
      billingInterval,
      fromBillingInterval 
    } = await request.json()

    if (!fromPlanId || !toPlanId) {
      return new Response(
      JSON.stringify({ 
        error: 'Missing required fields: fromPlanId, toPlanId' 
      ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    // Get current subscription and user data
    const [subscription, userProfile] = await Promise.all([
      getSubscriptionDetails(user.id),
      getUserProfile(user.id)
    ])

    // Run all validations
    const validations = await Promise.all([
      // Basic plan transition validation
      Promise.resolve(validatePlanTransition(fromPlanId, toPlanId, user.id)),
      
      // Billing interval validation (if changing)
      billingInterval && fromBillingInterval 
        ? Promise.resolve(validateBillingIntervalChange(toPlanId, fromBillingInterval, billingInterval))
        : Promise.resolve({ valid: true }),
      
      // Usage-based validation
      validateUserUsageForPlan(user.id, toPlanId),
      
      // Payment method validation
      validatePaymentMethodForPlan(user.id, toPlanId),
      
      // Business rules validation
      validateBusinessRules({
        userId: user.id,
        fromPlanId,
        toPlanId,
        billingInterval,
        userProfile,
        subscription
      })
    ])

    // Check if any validation failed
    const failedValidation = validations.find(v => !v.valid)
    if (failedValidation) {
      return new Response(
      JSON.stringify({
        valid: false,
        error: failedValidation.error,
        requirements: failedValidation.requirements
      ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    // Collect all warnings and requirements
    const allWarnings = validations
      .flatMap(v => v.warnings || [])
      .filter(Boolean)

    const allRequirements = validations
      .flatMap(v => v.requirements || [])
      .filter(Boolean)

    return new Response(
      JSON.stringify({
      valid: true,
      warnings: allWarnings.length > 0 ? allWarnings : undefined,
      requirements: allRequirements.length > 0 ? allRequirements : undefined,
      planTransition: {
        from: fromPlanId,
        to: toPlanId,
        type: getPlanTransitionType(fromPlanId, toPlanId)
      }
    })

  } catch (error) {
    console.error('Plan validation error:', error)
    return new Response(
      JSON.stringify({ 
      error: 'Validation failed. Please try again.' 
    ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}

async function getUserProfile(userId: string) {
  const supabase = createServerUserClient()
  
  const { data } = await supabase
    .from('users')
    .select('*')
    .eq('id', userId)
    .single()
    
  return data
}
```

## Frontend Validation Components

### Validation Hook

```typescript
// hooks/usePlanValidation.ts
import { useState } from 'react'

export function usePlanValidation() {
  const [loading, setLoading] = useState(false)
  const [result, setResult] = useState<ValidationResult | null>(null)

  const validatePlanChange = async (
    fromPlanId: string,
    toPlanId: string,
    billingInterval?: 'month' | 'year',
    fromBillingInterval?: 'month' | 'year'
  ) => {
    setLoading(true)
    setResult(null)

    try {
      const response = await fetch('/api/plans/validate-change', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          fromPlanId,
          toPlanId,
          billingInterval,
          fromBillingInterval
        }),
      })

      const data = await response.json()

      if (!response.ok) {
        setResult({
          valid: false,
          error: data.error,
          requirements: data.requirements
        })
      } else {
        setResult(data)
      }

      return data
    } catch (error) {
      const errorResult = {
        valid: false,
        error: 'Validation request failed. Please try again.'
      }
      setResult(errorResult)
      return errorResult
    } finally {
      setLoading(false)
    }
  }

  return {
    validatePlanChange,
    loading,
    result,
    clearResult: () => setResult(null)
  }
}
```

### Validation Warning Component

```typescript
// components/billing/ValidationWarnings.tsx
interface ValidationWarningsProps {
  warnings?: string[]
  requirements?: string[]
  onAccept: () => void
  onCancel: () => void
  acceptText?: string
  cancelText?: string
}

export function ValidationWarnings({
  warnings = [],
  requirements = [],
  onAccept,
  onCancel,
  acceptText = 'Continue Anyway',
  cancelText = 'Cancel'
}: ValidationWarningsProps) {
  if (warnings.length === 0 && requirements.length === 0) {
    return null
  }

  return (
    <div className="bg-yellow-50 border border-yellow-200 rounded-md p-4">
      <div className="flex">
        <div className="flex-shrink-0">
          <ExclamationTriangleIcon className="h-5 w-5 text-yellow-400" />
        </div>
        <div className="ml-3 flex-1">
          <h3 className="text-sm font-medium text-yellow-800">
            Please Review Before Continuing
          </h3>
          
          {warnings.length > 0 && (
            <div className="mt-2">
              <p className="text-sm text-yellow-700 font-medium">Warnings:</p>
              <ul className="mt-1 text-sm text-yellow-700 list-disc list-inside">
                {warnings.map((warning, index) => (
                  <li key={index}>{warning}</li>
                ))}
              </ul>
            </div>
          )}

          {requirements.length > 0 && (
            <div className="mt-2">
              <p className="text-sm text-yellow-700 font-medium">Requirements:</p>
              <ul className="mt-1 text-sm text-yellow-700 list-disc list-inside">
                {requirements.map((requirement, index) => (
                  <li key={index}>{requirement}</li>
                ))}
              </ul>
            </div>
          )}

          <div className="mt-4 flex space-x-3">
            <button
              onClick={onAccept}
              className="text-sm bg-yellow-100 text-yellow-800 hover:bg-yellow-200 px-3 py-1 rounded-md font-medium"
            >
              {acceptText}
            </button>
            <button
              onClick={onCancel}
              className="text-sm text-yellow-800 hover:text-yellow-900 font-medium"
            >
              {cancelText}
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}
```

## Testing Plan Validation

### Unit Tests

```typescript
// __tests__/lib/plan-validation.test.ts
import { validatePlanTransition, validateBillingIntervalChange } from '@/lib/plan-validation'

describe('Plan Validation', () => {
  describe('validatePlanTransition', () => {
    it('should allow valid upgrades', () => {
      const result = validatePlanTransition('free', 'starter')
      expect(result.valid).toBe(true)
    })

    it('should allow valid downgrades with warnings', () => {
      const result = validatePlanTransition('pro', 'starter')
      expect(result.valid).toBe(true)
      expect(result.warnings).toBeDefined()
      expect(result.warnings?.length).toBeGreaterThan(0)
    })

    it('should reject invalid transitions', () => {
      const result = validatePlanTransition('free', 'enterprise')
      expect(result.valid).toBe(false)
      expect(result.error).toContain('not allowed')
    })

    it('should reject same plan transitions', () => {
      const result = validatePlanTransition('starter', 'starter')
      expect(result.valid).toBe(false)
      expect(result.error).toContain('same plan')
    })
  })

  describe('validateBillingIntervalChange', () => {
    it('should allow monthly to annual for plans that support both', () => {
      const result = validateBillingIntervalChange('starter', 'month', 'year')
      expect(result.valid).toBe(true)
      expect(result.warnings).toBeDefined()
    })

    it('should reject interval changes for plans that don\'t support target interval', () => {
      const result = validateBillingIntervalChange('free', 'month', 'year')
      expect(result.valid).toBe(false)
      expect(result.error).toContain('not available')
    })
  })
})
```

### Integration Tests

```typescript
// __tests__/api/plans/validate-change.test.ts
import { POST } from '@/app/api/plans/validate-change/route'
import { Request } from 'next/server'

describe('/api/plans/validate-change', () => {
  it('should validate successful plan transitions', async () => {
    const request = new Request('http://localhost:3000/api/plans/validate-change', {
      method: 'POST',
      body: JSON.stringify({
        fromPlanId: 'free',
        toPlanId: 'starter'
      })
    })

    const response = await POST(request)
    const data = await response.json()

    expect(response.status).toBe(200)
    expect(data.valid).toBe(true)
    expect(data.planTransition.type).toBe('upgrade')
  })

  it('should reject invalid plan transitions', async () => {
    const request = new Request('http://localhost:3000/api/plans/validate-change', {
      method: 'POST',
      body: JSON.stringify({
        fromPlanId: 'starter',
        toPlanId: 'invalid_plan'
      })
    })

    const response = await POST(request)
    const data = await response.json()

    expect(response.status).toBe(400)
    expect(data.valid).toBe(false)
    expect(data.error).toContain('Invalid target plan')
  })
})
```

## Next Steps

In the next module, we'll cover implementing plan-based feature gating to control access based on subscription tiers.

## Key Takeaways

- Implement validation at multiple layers for robust plan changes
- Use business rules engine for complex validation logic
- Validate user usage against target plan limits
- Check payment methods for paid plan upgrades
- Provide clear warnings and requirements to users
- Handle edge cases like trials and geographic restrictions
- Test validation logic thoroughly with unit and integration tests
- Use hooks for clean frontend validation integration
- Display validation results clearly to users
- Enforce validation rules consistently across the application
