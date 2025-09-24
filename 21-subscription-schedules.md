# Using Stripe Subscription Schedules Effectively

## Overview

This module covers mastering Stripe Subscription Schedules, which are essential for complex billing scenarios in your codebase. We'll explore how to use phases, manage schedule lifecycle, and coordinate schedules with your database state.

## Subscription Schedules Fundamentals

Based on your codebase analysis, Subscription Schedules are used for:

### When to Use Schedules

1. **Interval Changes**: Annual → Monthly transitions
2. **Complex Upgrades**: Plan + interval changes simultaneously  
3. **Deferred Changes**: Any change that should happen at period end
4. **Trial Extensions**: Managing trial periods and transitions

### When NOT to Use Schedules

1. **Simple Upgrades**: Same interval, immediate changes
2. **Immediate Downgrades to Free**: Use `cancel_at_period_end`
3. **Payment Method Changes**: Use customer portal or payment methods API

## Phase-Based Architecture

Your codebase models complex changes using phases:

### Phase Concepts

```typescript
// lib/subscription-phases.ts
export interface SubscriptionPhase {
  items: Array<{
    price: string
    quantity: number
  }>
  start_date: number  // Unix timestamp
  end_date?: number   // Unix timestamp (optional for final phase)
  trial_end?: number  // Unix timestamp for trial phases
  metadata?: Record<string, string>
}

export interface ScheduleConfig {
  subscription_id: string
  phases: SubscriptionPhase[]
  metadata?: Record<string, string>
  end_behavior?: 'release' | 'cancel'
}
```

### Creating Phases for Interval Changes

```typescript
// From your codebase pattern
export async function createIntervalChangeSchedule(
  stripe: Stripe,
  subscriptionId: string,
  currentPriceId: string,
  targetPriceId: string,
  currentPeriodStart: number,
  currentPeriodEnd: number
): Promise<string> {
  
  console.log('📅 Creating subscription schedule for interval change')

  try {
    // Step 1: Create schedule from existing subscription
    const schedule = await stripe.subscriptionSchedules.create({
      from_subscription: subscriptionId,
    })

    console.log('✅ Created base schedule:', schedule.id)

    // Step 2: Update with phases (separate call per Stripe API requirements)
    await stripe.subscriptionSchedules.update(schedule.id, {
      phases: [
        // Phase 1: Current plan until period end
        {
          items: [{ price: currentPriceId, quantity: 1 }],
          start_date: currentPeriodStart,
          end_date: currentPeriodEnd,
        },
        // Phase 2: Target interval starting at renewal
        {
          items: [{ price: targetPriceId, quantity: 1 }],
          start_date: currentPeriodEnd,
          // No end_date = continues indefinitely
        }
      ],
      metadata: {
        ffm_interval_switch: '1',
        ffm_created_at: new Date().toISOString(),
        ffm_original_price: currentPriceId,
        ffm_target_price: targetPriceId
      }
    })

    console.log('✅ Updated schedule with phases')
    return schedule.id

  } catch (error) {
    console.error('❌ Schedule creation failed:', error)
    throw error
  }
}
```

### API Constraints and Workarounds

Your codebase documents important Stripe API constraints:

```typescript
// From docs/stripe-upgrades-downgrades.md constraints
export async function createScheduleWithConstraints(
  stripe: Stripe,
  subscriptionId: string
): Promise<string> {
  
  // IMPORTANT: Stripe API constraint from your codebase
  // When calling subscriptionSchedules.create({ from_subscription }):
  // - Do NOT include phases, end_behavior, or metadata in the same call
  // - First create the schedule only with from_subscription
  // - Then update the schedule with phases in a follow-up call

  try {
    // Step 1: Create schedule (minimal call)
    const schedule = await stripe.subscriptionSchedules.create({
      from_subscription: subscriptionId
      // DO NOT include phases, end_behavior, or metadata here
    })

    // Step 2: Update with phases (separate call)
    const updatedSchedule = await stripe.subscriptionSchedules.update(schedule.id, {
      phases: [
        // Define phases here
      ],
      end_behavior: 'release',
      metadata: {
        // Add metadata here
      }
    })

    return schedule.id

  } catch (error) {
    console.error('❌ Schedule creation with constraints failed:', error)
    throw error
  }
}
```

## Schedule Management Functions

### Schedule Lifecycle Management

```typescript
// lib/schedule-lifecycle.ts
export async function manageScheduleLifecycle(
  scheduleId: string,
  action: 'cancel' | 'release' | 'update'
): Promise<{ success: boolean; schedule?: any; error?: string }> {
  
  try {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    let result: any

    switch (action) {
      case 'cancel':
        result = await stripe.subscriptionSchedules.cancel(scheduleId)
        console.log(`✅ Cancelled schedule: ${scheduleId}`)
        break

      case 'release':
        result = await stripe.subscriptionSchedules.release(scheduleId)
        console.log(`✅ Released schedule: ${scheduleId}`)
        break

      case 'update':
        // For updates, you'd pass additional parameters
        result = await stripe.subscriptionSchedules.retrieve(scheduleId)
        console.log(`✅ Retrieved schedule: ${scheduleId}`)
        break

      default:
        throw new Error(`Invalid schedule action: ${action}`)
    }

    return { success: true, schedule: result }

  } catch (error) {
    console.error(`❌ Schedule ${action} failed:`, error)
    return { 
      success: false, 
      error: error instanceof Error ? error.message : 'Schedule operation failed' 
    }
  }
}

export async function getActiveSchedulesForSubscription(
  subscriptionId: string
): Promise<any[]> {
  
  try {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    const schedules = await stripe.subscriptionSchedules.list({
      subscription: subscriptionId,
      limit: 10
    })

    // Filter for active schedules
    return schedules.data.filter(schedule => schedule.status === 'active')

  } catch (error) {
    console.error('❌ Error fetching schedules:', error)
    return []
  }
}
```

### Schedule Status Monitoring

```typescript
// lib/schedule-monitoring.ts
export async function monitorScheduleStatus(
  scheduleId: string
): Promise<{
  status: string
  currentPhase: number
  nextPhaseDate?: string
  phasesTotal: number
}> {
  
  try {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    const schedule = await stripe.subscriptionSchedules.retrieve(scheduleId)
    
    const phases = schedule.phases || []
    const currentPhaseStart = schedule.current_phase?.start_date
    
    let currentPhaseIndex = 0
    let nextPhaseDate: string | undefined

    if (currentPhaseStart && phases.length > 0) {
      currentPhaseIndex = phases.findIndex(p => p.start_date === currentPhaseStart)
      
      // Find next phase
      if (currentPhaseIndex >= 0 && currentPhaseIndex < phases.length - 1) {
        const nextPhase = phases[currentPhaseIndex + 1]
        nextPhaseDate = new Date(nextPhase.start_date * 1000).toISOString()
      }
    }

    return {
      status: schedule.status,
      currentPhase: currentPhaseIndex + 1,
      nextPhaseDate,
      phasesTotal: phases.length
    }

  } catch (error) {
    console.error('❌ Error monitoring schedule status:', error)
    throw error
  }
}
```

## Advanced Schedule Patterns

### Trial Extension with Schedules

```typescript
// lib/trial-extension.ts
export async function extendTrialWithSchedule(
  subscriptionId: string,
  extensionDays: number,
  targetPriceId: string
): Promise<string> {
  
  try {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    const subscription = await stripe.subscriptions.retrieve(subscriptionId)
    
    if (subscription.status !== 'trialing') {
      throw new Error('Subscription is not in trial period')
    }

    const currentTrialEnd = subscription.trial_end!
    const extendedTrialEnd = currentTrialEnd + (extensionDays * 24 * 60 * 60) // Add days in seconds

    // Create schedule with extended trial
    const schedule = await stripe.subscriptionSchedules.create({
      from_subscription: subscriptionId,
    })

    await stripe.subscriptionSchedules.update(schedule.id, {
      phases: [
        // Extended trial phase
        {
          items: [{ price: targetPriceId, quantity: 1 }],
          start_date: subscription.current_period_start,
          trial_end: extendedTrialEnd
        }
        // After trial_end, normal billing begins automatically
      ],
      metadata: {
        ffm_trial_extension: '1',
        ffm_extension_days: extensionDays.toString(),
        ffm_original_trial_end: currentTrialEnd.toString()
      }
    })

    console.log(`✅ Extended trial by ${extensionDays} days`)
    return schedule.id

  } catch (error) {
    console.error('❌ Trial extension failed:', error)
    throw error
  }
}
```

### Seasonal Pricing with Schedules

```typescript
// lib/seasonal-pricing.ts
export async function createSeasonalPricingSchedule(
  subscriptionId: string,
  seasonalPhases: Array<{
    priceId: string
    startDate: Date
    endDate?: Date
    description: string
  }>
): Promise<string> {
  
  try {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    const schedule = await stripe.subscriptionSchedules.create({
      from_subscription: subscriptionId,
    })

    // Convert to Stripe phase format
    const phases = seasonalPhases.map((phase, index) => ({
      items: [{ price: phase.priceId, quantity: 1 }],
      start_date: Math.floor(phase.startDate.getTime() / 1000),
      end_date: phase.endDate ? Math.floor(phase.endDate.getTime() / 1000) : undefined,
      metadata: {
        phase_description: phase.description,
        phase_index: index.toString()
      }
    }))

    await stripe.subscriptionSchedules.update(schedule.id, {
      phases,
      metadata: {
        ffm_seasonal_pricing: '1',
        ffm_phases_count: phases.length.toString()
      }
    })

    console.log('✅ Seasonal pricing schedule created')
    return schedule.id

  } catch (error) {
    console.error('❌ Seasonal pricing schedule failed:', error)
    throw error
  }
}
```

## Schedule Webhook Handling

### Enhanced Schedule Event Processing

```typescript
// Enhanced webhook handlers for schedules
export async function handleSubscriptionScheduleCreated(schedule: any) {
  console.log('📅 Processing subscription_schedule.created')
  
  const subscriptionId = schedule.subscription
  const metadata = schedule.metadata || {}
  
  if (!subscriptionId) {
    console.log('❌ No subscription ID found')
    return
  }

  try {
    const supabase = createServerServiceRoleClient()
    
    // Check schedule type from metadata
    const isIntervalSwitch = metadata['ffm_interval_switch'] === '1'
    const isTrialExtension = metadata['ffm_trial_extension'] === '1'
    const isSeasonalPricing = metadata['ffm_seasonal_pricing'] === '1'

    if (isIntervalSwitch) {
      console.log('📅 Interval switch schedule created - no cancel_at_period_end needed')
      return
    }

    if (isTrialExtension) {
      await handleTrialExtensionSchedule(schedule)
      return
    }

    if (isSeasonalPricing) {
      await handleSeasonalPricingSchedule(schedule)
      return
    }

    // Default behavior for downgrade schedules
    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        cancel_at_period_end: true,
        updated_at: new Date().toISOString(),
      })
      .eq('stripe_subscription_id', subscriptionId)
      .select()
      .single()

    if (error) {
      console.error('❌ Error updating subscription for schedule:', error)
      return
    }

    console.log('✅ Subscription marked for scheduled change')
    return data

  } catch (error) {
    console.error('❌ Exception in handleSubscriptionScheduleCreated:', error)
  }
}

export async function handleSubscriptionScheduleReleased(schedule: any) {
  console.log('📅 Processing subscription_schedule.released')
  
  const releasedSubscriptionId = schedule.released_subscription
  
  if (!releasedSubscriptionId) {
    console.log('❌ No released subscription ID found')
    return
  }

  try {
    const supabase = createServerServiceRoleClient()
    
    // Clear any scheduled changes when schedule is released
    const { data: subscription, error: readError } = await supabase
      .from('subscriptions')
      .select('id, metadata')
      .eq('stripe_subscription_id', releasedSubscriptionId)
      .single()

    if (readError || !subscription) {
      console.error('❌ Subscription not found for released schedule:', readError)
      return
    }

    const currentMetadata = (subscription.metadata || {}) as any
    const { 
      scheduled_change, 
      interval_change_context, 
      mixed_upgrade_context,
      ...remainingMetadata 
    } = currentMetadata

    // Update subscription to clear scheduled changes
    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        cancel_at_period_end: false,
        metadata: {
          ...remainingMetadata,
          schedule_release_history: [
            ...(remainingMetadata.schedule_release_history || []),
            {
              released_at: new Date().toISOString(),
              schedule_id: schedule.id,
              released_change: scheduled_change
            }
          ]
        },
        updated_at: new Date().toISOString(),
      })
      .eq('stripe_subscription_id', releasedSubscriptionId)
      .select()
      .single()

    if (error) {
      console.error('❌ Error updating subscription after schedule release:', error)
      return
    }

    console.log(`✅ Cleared scheduled changes for released subscription ${releasedSubscriptionId}`)
    return data

  } catch (error) {
    console.error('❌ Exception in handleSubscriptionScheduleReleased:', error)
  }
}
```

## Advanced Schedule Operations

### Schedule Modification

```typescript
// lib/schedule-modification.ts
export async function modifyExistingSchedule(
  scheduleId: string,
  modifications: {
    addPhase?: SubscriptionPhase
    updatePhase?: { index: number; phase: Partial<SubscriptionPhase> }
    removePhase?: number
    updateMetadata?: Record<string, string>
  }
): Promise<{ success: boolean; schedule?: any; error?: string }> {
  
  try {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    // Get current schedule
    const currentSchedule = await stripe.subscriptionSchedules.retrieve(scheduleId)
    const currentPhases = [...(currentSchedule.phases || [])]

    // Apply modifications
    if (modifications.addPhase) {
      currentPhases.push(modifications.addPhase)
    }

    if (modifications.updatePhase) {
      const { index, phase } = modifications.updatePhase
      if (currentPhases[index]) {
        currentPhases[index] = { ...currentPhases[index], ...phase }
      }
    }

    if (modifications.removePhase !== undefined) {
      currentPhases.splice(modifications.removePhase, 1)
    }

    // Update schedule
    const updatedSchedule = await stripe.subscriptionSchedules.update(scheduleId, {
      phases: currentPhases,
      metadata: {
        ...currentSchedule.metadata,
        ...modifications.updateMetadata,
        last_modified: new Date().toISOString()
      }
    })

    console.log('✅ Schedule modified successfully')
    return { success: true, schedule: updatedSchedule }

  } catch (error) {
    console.error('❌ Schedule modification failed:', error)
    return { 
      success: false, 
      error: error instanceof Error ? error.message : 'Modification failed' 
    }
  }
}
```

### Schedule Conflict Resolution

```typescript
// lib/schedule-conflicts.ts
export async function resolveScheduleConflicts(
  subscriptionId: string
): Promise<{ resolved: boolean; conflicts: string[]; actions: string[] }> {
  
  try {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    // Get all schedules for subscription
    const schedules = await stripe.subscriptionSchedules.list({
      subscription: subscriptionId,
      limit: 10
    })

    const activeSchedules = schedules.data.filter(s => s.status === 'active')
    const conflicts: string[] = []
    const actions: string[] = []

    if (activeSchedules.length > 1) {
      conflicts.push(`Multiple active schedules found: ${activeSchedules.length}`)
      
      // Cancel all but the most recent
      const sortedSchedules = activeSchedules.sort((a, b) => b.created - a.created)
      const keepSchedule = sortedSchedules[0]
      const cancelSchedules = sortedSchedules.slice(1)

      for (const schedule of cancelSchedules) {
        await stripe.subscriptionSchedules.cancel(schedule.id)
        actions.push(`Cancelled duplicate schedule: ${schedule.id}`)
      }

      actions.push(`Kept most recent schedule: ${keepSchedule.id}`)
    }

    // Check for phase conflicts
    for (const schedule of activeSchedules) {
      const phases = schedule.phases || []
      
      // Check for overlapping phases
      for (let i = 0; i < phases.length - 1; i++) {
        const currentPhase = phases[i]
        const nextPhase = phases[i + 1]
        
        if (currentPhase.end_date && nextPhase.start_date) {
          if (currentPhase.end_date > nextPhase.start_date) {
            conflicts.push(`Overlapping phases in schedule ${schedule.id}`)
          }
        }
      }
    }

    return {
      resolved: conflicts.length === 0,
      conflicts,
      actions
    }

  } catch (error) {
    console.error('❌ Schedule conflict resolution failed:', error)
    return {
      resolved: false,
      conflicts: ['Failed to resolve conflicts'],
      actions: []
    }
  }
}
```

## Testing Subscription Schedules

### Schedule Testing Utilities

```typescript
// cypress/support/schedule-helpers.ts
export async function getSubscriptionScheduleForEmail(email: string) {
  try {
    const user = await getUserByEmail(email)
    
    const { data: subscription } = await supabaseAdmin
      .from('subscriptions')
      .select('stripe_subscription_id')
      .eq('user_id', user.id)
      .single()

    if (!subscription?.stripe_subscription_id) {
      return { ok: false, error: 'No subscription found' }
    }

    // Get schedules from Stripe
    const schedules = await stripe.subscriptionSchedules.list({
      subscription: subscription.stripe_subscription_id,
      limit: 1
    })

    if (schedules.data.length === 0) {
      return { ok: false, error: 'No schedules found' }
    }

    const schedule = schedules.data[0]
    
    return {
      ok: true,
      scheduleId: schedule.id,
      status: schedule.status,
      phasesCount: schedule.phases?.length || 0
    }

  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    }
  }
}

export async function getSubscriptionSchedulePhasesForEmail(email: string) {
  try {
    const scheduleResult = await getSubscriptionScheduleForEmail(email)
    
    if (!scheduleResult.ok) {
      return scheduleResult
    }

    const schedule = await stripe.subscriptionSchedules.retrieve(scheduleResult.scheduleId)
    const phases = schedule.phases || []

    // Analyze phases for testing
    const hasMonthlyTarget = phases.some(phase => 
      phase.items?.some(item => 
        item.price?.includes('monthly') || 
        schedule.metadata?.ffm_target_interval === 'month'
      )
    )

    const hasAnnualTarget = phases.some(phase => 
      phase.items?.some(item => 
        item.price?.includes('annual') || 
        schedule.metadata?.ffm_target_interval === 'year'
      )
    )

    return {
      ok: true,
      scheduleId: schedule.id,
      phasesCount: phases.length,
      hasMonthlyTarget,
      hasAnnualTarget,
      currentPhase: schedule.current_phase?.start_date,
      metadata: schedule.metadata
    }

  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    }
  }
}
```

### E2E Schedule Tests

```typescript
// cypress/e2e/billing/subscription-schedules.cy.ts
describe('Subscription Schedules', () => {
  describe('Schedule Creation and Management', () => {
    const email = `schedule-test-${Date.now()}@example.com`

    beforeEach(() => {
      cy.seedProAnnualUser({ email })
      cy.login(email)
    })

    it('should create schedule for interval change', () => {
      cy.visit('/billing')

      // Switch to monthly and trigger schedule creation
      cy.get('[data-testid="billing-toggle-monthly"]').click()
      cy.get('[data-testid="pro-action-button"]').click()
      
      cy.get('[data-testid="downgrade-modal"]').should('be.visible')
      cy.intercept('POST', '/api/billing/downgrade').as('createSchedule')
      cy.get('[data-testid="confirm-downgrade"]').click()

      cy.wait('@createSchedule').then((interception) => {
        expect(interception.response?.statusCode).to.eq(200)
      })

      // Verify schedule was created
      cy.task('getSubscriptionScheduleForEmail', { email }).then((res: any) => {
        expect(res.ok).to.be.true
        expect(res.scheduleId).to.be.a('string')
        expect(res.status).to.eq('active')
      })

      // Verify phases are configured correctly
      cy.task('getSubscriptionSchedulePhasesForEmail', { email }).then((res: any) => {
        expect(res.ok).to.be.true
        expect(res.phasesCount).to.eq(2)
        expect(res.hasMonthlyTarget).to.be.true
      })
    })

    it('should handle schedule cancellation', () => {
      // First create a schedule
      cy.visit('/billing')
      cy.get('[data-testid="billing-toggle-monthly"]').click()
      cy.get('[data-testid="pro-action-button"]').click()
      cy.get('[data-testid="confirm-downgrade"]').click()

      // Wait for schedule creation
      cy.get('[data-testid="scheduled-change-banner"]').should('be.visible')

      // Cancel the scheduled change
      cy.intercept('POST', '/api/billing/cancel-plan-change').as('cancelSchedule')
      cy.get('[data-testid="cancel-scheduled-change"]').click()

      cy.wait('@cancelSchedule').then((interception) => {
        expect(interception.response?.statusCode).to.eq(200)
      })

      // Verify schedule was cancelled
      cy.task('getSubscriptionScheduleForEmail', { email }).then((res: any) => {
        // Schedule should either be cancelled or not exist
        expect(res.ok === false || res.status === 'canceled').to.be.true
      })

      // Banner should disappear
      cy.get('[data-testid="scheduled-change-banner"]').should('not.exist')
    })
  })
})
```

## Next Steps

In the next module, we'll cover building seamless customer-facing billing interfaces, including the Stripe Customer Portal vs custom interfaces.

## Key Takeaways

- Use subscription schedules for complex timing requirements
- Follow Stripe API constraints when creating schedules (separate create and update calls)
- Implement proper phase management for multi-step changes
- Handle schedule conflicts and duplicate schedules
- Use metadata to track schedule context and purpose
- Test schedule creation, modification, and cancellation thoroughly
- Monitor schedule status and phase transitions
- Coordinate schedule events with database state via webhooks
- Implement schedule-based features like trial extensions and seasonal pricing
- Provide clear UI feedback about scheduled changes and their timing
