# Plan Configuration and Management

## Overview

This module covers how to structure and manage your pricing plans, including the JSON-based configuration system used in your codebase, plan validation logic, and upgrade/downgrade rules.

## Plan Configuration Architecture

Your codebase uses a centralized JSON configuration file to define all plans and pricing:

### Core Configuration Structure

```json
// config/plans.json
{
  "plans": {
    "free": {
      "name": "Free Plan",
      "monthly": {
        "priceCents": 0,
        "stripePriceId": "price_1S1EldHxCxqKRRWFkYhT6myo"
      },
      "annual": null,
      "includedComputeMinutes": 100,
      "concurrencyLimit": 1,
      "allowOverages": false,
      "overagePricePerMinuteCents": null,
      "isFree": true,
      "upgradePlans": ["starter", "pro", "scale"],
      "downgradePlans": []
    },
    "starter": {
      "name": "Starter Plan",
      "monthly": {
        "priceCents": 1900,
        "stripePriceId": "price_1S1EmGHxCxqKRRWFzsKZxGSY"
      },
      "annual": {
        "priceCents": 12900,
        "stripePriceId": "price_1S3QQRHxCxqKRRWFm0GiuYxe"
      },
      "includedComputeMinutes": 2000,
      "concurrencyLimit": 3,
      "allowOverages": true,
      "overagePricePerMinuteCents": 10,
      "isFree": false,
      "upgradePlans": ["pro", "scale"],
      "downgradePlans": ["free"]
    },
    "pro": {
      "name": "Pro Plan",
      "monthly": {
        "priceCents": 8900,
        "stripePriceId": "price_1S1EmZHxCxqKRRWF8fQgO6d2"
      },
      "annual": {
        "priceCents": 59900,
        "stripePriceId": "price_1S3QRLHxCxqKRRWF2vbYYoZg"
      },
      "includedComputeMinutes": 12000,
      "concurrencyLimit": 10,
      "allowOverages": true,
      "overagePricePerMinuteCents": 8,
      "isFree": false,
      "upgradePlans": ["scale"],
      "downgradePlans": ["free", "starter"]
    },
    "scale": {
      "name": "Scale Plan",
      "monthly": {
        "priceCents": 34900,
        "stripePriceId": "price_1S1EmyHxCxqKRRWFt5THBV92"
      },
      "annual": {
        "priceCents": 249900,
        "stripePriceId": "price_1S3QPLHxCxqKRRWFXYjReKs1"
      },
      "includedComputeMinutes": 60000,
      "concurrencyLimit": 40,
      "allowOverages": true,
      "overagePricePerMinuteCents": 6,
      "isFree": false,
      "upgradePlans": [],
      "downgradePlans": ["free", "starter", "pro"]
    }
  }
}
```

## TypeScript Interface Definition

Your codebase defines a strong TypeScript interface for plan configuration:

```typescript
// lib/plan-config.ts
export interface PlanConfig {
  name: string
  monthly: {
    priceCents: number
    stripePriceId: string
  } | null
  annual: {
    priceCents: number
    stripePriceId: string
  } | null
  includedComputeMinutes: number
  concurrencyLimit: number
  allowOverages: boolean
  overagePricePerMinuteCents: number | null
  isFree: boolean
  upgradePlans: string[]
  downgradePlans: string[]
}
```

**Key Design Decisions**:
- **Flexible billing intervals**: Plans can have monthly, annual, or both
- **Feature limits**: Each plan defines resource limits and capabilities
- **Upgrade/downgrade rules**: Explicit allowed transitions between plans
- **Stripe integration**: Direct mapping to Stripe price IDs
- **Usage pricing**: Support for overage charges

## Plan Configuration Functions

### Basic Plan Operations

```typescript
// lib/plan-config.ts
import plansConfig from '../config/plans.json'

export function getPlanConfig(planId: string): PlanConfig | null {
  const plan = (plansConfig.plans as Record<string, PlanConfig>)[planId]
  return plan || null
}

export function getAllPlans(): Record<string, PlanConfig> {
  return plansConfig.plans as Record<string, PlanConfig>
}

export function getAvailableBillingIntervals(planId: string): ('month' | 'year')[] {
  const plan = getPlanConfig(planId)
  if (!plan) return []
  
  const intervals: ('month' | 'year')[] = []
  if (plan.monthly) intervals.push('month')
  if (plan.annual) intervals.push('year')
  
  return intervals
}
```

### Price and Stripe Integration

```typescript
export function getStripePriceId(planId: string, billingInterval: 'month' | 'year'): string | null {
  const plan = getPlanConfig(planId)
  if (!plan) return null
  
  if (billingInterval === 'month') {
    return plan.monthly?.stripePriceId || null
  } else {
    return plan.annual?.stripePriceId || null
  }
}

export function getPlanPrice(planId: string, billingInterval: 'month' | 'year'): number {
  const plan = getPlanConfig(planId)
  if (!plan) return 0
  
  if (billingInterval === 'month') {
    return plan.monthly?.priceCents || 0
  } else {
    return plan.annual?.priceCents || 0
  }
}

export function derivePlanIdFromPrice(stripePriceId: string): string | null {
  const plans = getAllPlans()
  
  for (const [planId, planConfig] of Object.entries(plans)) {
    if (planConfig.monthly?.stripePriceId === stripePriceId ||
        planConfig.annual?.stripePriceId === stripePriceId) {
      return planId
    }
  }
  
  return null
}
```

### Plan Validation Logic

```typescript
export function canUpgradeTo(fromPlanId: string, toPlanId: string): boolean {
  const fromPlan = getPlanConfig(fromPlanId)
  return fromPlan ? fromPlan.upgradePlans.includes(toPlanId) : false
}

export function canDowngradeTo(fromPlanId: string, toPlanId: string): boolean {
  const fromPlan = getPlanConfig(fromPlanId)
  return fromPlan ? fromPlan.downgradePlans.includes(toPlanId) : false
}

export function isValidPlanTransition(fromPlanId: string, toPlanId: string): boolean {
  if (fromPlanId === toPlanId) return false // Same plan
  
  return canUpgradeTo(fromPlanId, toPlanId) || canDowngradeTo(fromPlanId, toPlanId)
}

export function getPlanTransitionType(fromPlanId: string, toPlanId: string): 'upgrade' | 'downgrade' | 'invalid' {
  if (canUpgradeTo(fromPlanId, toPlanId)) return 'upgrade'
  if (canDowngradeTo(fromPlanId, toPlanId)) return 'downgrade'
  return 'invalid'
}
```

## Advanced Plan Logic

### Price Comparison

```typescript
export function comparePlanPrices(
  plan1Id: string, 
  plan2Id: string, 
  billingInterval: 'month' | 'year'
): 'higher' | 'lower' | 'equal' | 'incomparable' {
  const price1 = getPlanPrice(plan1Id, billingInterval)
  const price2 = getPlanPrice(plan2Id, billingInterval)
  
  if (price1 === 0 && price2 === 0) return 'equal'
  if (price1 === 0 || price2 === 0) return 'incomparable'
  
  if (price1 > price2) return 'higher'
  if (price1 < price2) return 'lower'
  return 'equal'
}

export function isUpgradeByPrice(
  fromPlanId: string, 
  toPlanId: string, 
  billingInterval: 'month' | 'year'
): boolean {
  const comparison = comparePlanPrices(fromPlanId, toPlanId, billingInterval)
  return comparison === 'lower' // From plan is lower priced than to plan
}
```

### Feature Comparison

```typescript
export function compareFeatureLimits(plan1Id: string, plan2Id: string): {
  computeMinutes: 'higher' | 'lower' | 'equal'
  concurrency: 'higher' | 'lower' | 'equal'
  overages: 'enabled' | 'disabled' | 'same'
} {
  const plan1 = getPlanConfig(plan1Id)
  const plan2 = getPlanConfig(plan2Id)
  
  if (!plan1 || !plan2) {
    throw new Error('Invalid plan IDs for comparison')
  }

  return {
    computeMinutes: 
      plan1.includedComputeMinutes > plan2.includedComputeMinutes ? 'higher' :
      plan1.includedComputeMinutes < plan2.includedComputeMinutes ? 'lower' : 'equal',
    
    concurrency:
      plan1.concurrencyLimit > plan2.concurrencyLimit ? 'higher' :
      plan1.concurrencyLimit < plan2.concurrencyLimit ? 'lower' : 'equal',
    
    overages:
      plan1.allowOverages === plan2.allowOverages ? 'same' :
      plan1.allowOverages ? 'enabled' : 'disabled'
  }
}
```

## Plan Display Logic

### Pricing Display

```typescript
// lib/plan-display.ts
export function formatPlanPrice(planId: string, billingInterval: 'month' | 'year'): string {
  const priceCents = getPlanPrice(planId, billingInterval)
  
  if (priceCents === 0) {
    return 'Free'
  }
  
  const dollars = Math.floor(priceCents / 100)
  const cents = priceCents % 100
  
  const priceString = cents === 0 ? `$${dollars}` : `$${dollars}.${cents.toString().padStart(2, '0')}`
  const intervalDisplay = billingInterval === 'month' ? 'mo' : 'yr'
  
  return `${priceString}/${intervalDisplay}`
}

export function calculateAnnualSavings(planId: string): { 
  savingsPercent: number 
  savingsAmount: number 
} | null {
  const plan = getPlanConfig(planId)
  if (!plan?.monthly || !plan?.annual) return null
  
  const monthlyAnnual = plan.monthly.priceCents * 12
  const annualPrice = plan.annual.priceCents
  
  if (monthlyAnnual <= annualPrice) return null
  
  const savingsAmount = monthlyAnnual - annualPrice
  const savingsPercent = Math.round((savingsAmount / monthlyAnnual) * 100)
  
  return { savingsPercent, savingsAmount }
}

export function getPlanDisplayData(planId: string, billingInterval: 'month' | 'year') {
  const plan = getPlanConfig(planId)
  if (!plan) return null
  
  const price = formatPlanPrice(planId, billingInterval)
  const savings = billingInterval === 'year' ? calculateAnnualSavings(planId) : null
  
  return {
    id: planId,
    name: plan.name,
    price,
    priceRaw: getPlanPrice(planId, billingInterval),
    features: {
      computeMinutes: plan.includedComputeMinutes,
      concurrency: plan.concurrencyLimit,
      overages: plan.allowOverages,
      overagePrice: plan.overagePricePerMinuteCents
    },
    savings,
    isFree: plan.isFree,
    availableIntervals: getAvailableBillingIntervals(planId)
  }
}
```

## Dynamic Plan Loading

### Environment-Based Configuration

```typescript
// lib/plan-loader.ts
export async function loadPlanConfiguration(): Promise<Record<string, PlanConfig>> {
  // In production, you might load from database or external API
  if (process.env.NODE_ENV === 'production' && process.env.DYNAMIC_PLANS === 'true') {
    return await loadPlansFromDatabase()
  }
  
  // Default to static configuration
  return getAllPlans()
}

async function loadPlansFromDatabase(): Promise<Record<string, PlanConfig>> {
  const supabase = createServerServiceRoleClient()
  
  const { data: plans, error } = await supabase
    .from('plan_configurations')
    .select('*')
    .eq('active', true)
  
  if (error) {
    console.error('Failed to load plans from database, falling back to static config:', error)
    return getAllPlans()
  }
  
  // Transform database format to PlanConfig format
  const planMap: Record<string, PlanConfig> = {}
  
  for (const plan of plans) {
    planMap[plan.plan_id] = {
      name: plan.name,
      monthly: plan.monthly_price_cents ? {
        priceCents: plan.monthly_price_cents,
        stripePriceId: plan.monthly_stripe_price_id
      } : null,
      annual: plan.annual_price_cents ? {
        priceCents: plan.annual_price_cents,
        stripePriceId: plan.annual_stripe_price_id
      } : null,
      includedComputeMinutes: plan.included_compute_minutes,
      concurrencyLimit: plan.concurrency_limit,
      allowOverages: plan.allow_overages,
      overagePricePerMinuteCents: plan.overage_price_per_minute_cents,
      isFree: plan.is_free,
      upgradePlans: plan.upgrade_plans || [],
      downgradePlans: plan.downgrade_plans || []
    }
  }
  
  return planMap
}
```

## Plan Validation API

### Validation Endpoint

```typescript
// app/api/plans/validate-transition/route.ts
export async function POST(request: Request) {
  try {
    const { fromPlanId, toPlanId, billingInterval } = await request.json()
    
    if (!fromPlanId || !toPlanId) {
      return new Response(
      JSON.stringify({ error: 'Missing plan IDs' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }
    
    // Validate plans exist
    const fromPlan = getPlanConfig(fromPlanId)
    const toPlan = getPlanConfig(toPlanId)
    
    if (!fromPlan || !toPlan) {
      return new Response(
      JSON.stringify({ error: 'Invalid plan ID' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }
    
    // Check if transition is allowed
    const transitionType = getPlanTransitionType(fromPlanId, toPlanId)
    if (transitionType === 'invalid') {
      return new Response(
      JSON.stringify({ 
        error: 'Plan transition not allowed',
        allowedUpgrades: fromPlan.upgradePlans,
        allowedDowngrades: fromPlan.downgradePlans
      ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }
    
    // Validate billing interval
    const availableIntervals = getAvailableBillingIntervals(toPlanId)
    if (billingInterval && !availableIntervals.includes(billingInterval)) {
      return new Response(
      JSON.stringify({ 
        error: 'Billing interval not available for target plan',
        availableIntervals
      ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }
    
    // Get price information
    const priceId = getStripePriceId(toPlanId, billingInterval || 'month')
    if (!priceId) {
      return new Response(
      JSON.stringify({ error: 'No price configured for plan and interval' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }
    
    return new Response(
      JSON.stringify({
      valid: true,
      transitionType,
      targetPriceId: priceId,
      targetPrice: getPlanPrice(toPlanId, billingInterval || 'month'),
      featureComparison: compareFeatureLimits(fromPlanId, toPlanId)
    })
  } catch (error) {
    console.error('Plan validation error:', error)
    return new Response(
      JSON.stringify({ error: 'Validation failed' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Plan Configuration Management

### Admin Interface for Plan Updates

```typescript
// lib/plan-admin.ts
export async function updatePlanConfiguration(
  planId: string, 
  updates: Partial<PlanConfig>
): Promise<boolean> {
  console.log(`🔧 Updating plan configuration for ${planId}`)
  
  try {
    // In a production system, you'd update your database
    // For now, this would require redeploying with updated JSON
    
    const currentPlan = getPlanConfig(planId)
    if (!currentPlan) {
      throw new Error(`Plan ${planId} not found`)
    }
    
    // Validate updates
    if (updates.monthly && !updates.monthly.stripePriceId) {
      throw new Error('Monthly pricing requires Stripe price ID')
    }
    
    if (updates.annual && !updates.annual.stripePriceId) {
      throw new Error('Annual pricing requires Stripe price ID')
    }
    
    // In a real implementation, save to database
    // await savePlanToDatabase(planId, { ...currentPlan, ...updates })
    
    console.log(`✅ Plan ${planId} configuration updated`)
    return true
  } catch (error) {
    console.error('❌ Error updating plan configuration:', error)
    return false
  }
}

export function validatePlanConfiguration(plan: PlanConfig): string[] {
  const errors: string[] = []
  
  if (!plan.name) {
    errors.push('Plan name is required')
  }
  
  if (!plan.monthly && !plan.annual) {
    errors.push('Plan must have at least one billing interval')
  }
  
  if (plan.monthly && (!plan.monthly.stripePriceId || plan.monthly.priceCents < 0)) {
    errors.push('Monthly pricing requires valid price and Stripe price ID')
  }
  
  if (plan.annual && (!plan.annual.stripePriceId || plan.annual.priceCents < 0)) {
    errors.push('Annual pricing requires valid price and Stripe price ID')
  }
  
  if (plan.includedComputeMinutes < 0) {
    errors.push('Included compute minutes cannot be negative')
  }
  
  if (plan.concurrencyLimit < 1) {
    errors.push('Concurrency limit must be at least 1')
  }
  
  if (plan.allowOverages && !plan.overagePricePerMinuteCents) {
    errors.push('Overage pricing required when overages are allowed')
  }
  
  return errors
}
```

## Testing Plan Configuration

### Unit Tests

```typescript
// __tests__/lib/plan-config.test.ts
import { 
  getPlanConfig, 
  canUpgradeTo, 
  canDowngradeTo,
  getPlanTransitionType,
  formatPlanPrice 
} from '@/lib/plan-config'

describe('Plan Configuration', () => {
  it('should get plan configuration', () => {
    const starter = getPlanConfig('starter')
    expect(starter).toBeDefined()
    expect(starter?.name).toBe('Starter Plan')
    expect(starter?.monthly?.priceCents).toBe(1900)
  })

  it('should validate upgrade transitions', () => {
    expect(canUpgradeTo('free', 'starter')).toBe(true)
    expect(canUpgradeTo('starter', 'pro')).toBe(true)
    expect(canUpgradeTo('pro', 'starter')).toBe(false)
  })

  it('should validate downgrade transitions', () => {
    expect(canDowngradeTo('starter', 'free')).toBe(true)
    expect(canDowngradeTo('pro', 'starter')).toBe(true)
    expect(canDowngradeTo('free', 'starter')).toBe(false)
  })

  it('should determine transition types', () => {
    expect(getPlanTransitionType('free', 'starter')).toBe('upgrade')
    expect(getPlanTransitionType('starter', 'free')).toBe('downgrade')
    expect(getPlanTransitionType('starter', 'scale')).toBe('invalid')
  })

  it('should format prices correctly', () => {
    expect(formatPlanPrice('free', 'month')).toBe('Free')
    expect(formatPlanPrice('starter', 'month')).toBe('$19/mo')
    expect(formatPlanPrice('pro', 'year')).toBe('$599/yr')
  })
})
```

## Next Steps

In the next module, we'll cover building dynamic pricing pages that use this plan configuration system to display pricing information to users.

## Key Takeaways

- Use centralized JSON configuration for plan management
- Define strong TypeScript interfaces for type safety
- Implement explicit upgrade/downgrade rules
- Map plans directly to Stripe price IDs
- Support flexible billing intervals (monthly/annual)
- Include feature limits and usage pricing in configuration
- Validate plan transitions before allowing changes
- Format pricing consistently across the application
- Test plan configuration logic thoroughly
- Consider dynamic plan loading for production systems
