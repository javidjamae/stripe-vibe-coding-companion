# Stripe for SaaS: A Vibe Coding Companion

Don't want to build this all yourself? 
- Check out our SaaS Starter Kit, that has ALL of this implemented already.
- [https://www.user-growth.com/saas-starter-kit](https://www.user-growth.com/saas-starter-kit)

Want support?
- Join the FREE SaaS User Growth Academy (SUGA) on Skool
- [https://www.skool.com/delivering-growth-free/about](https://www.skool.com/delivering-growth-free/about)

Want to work with us directly?
- Book a 15-minute discovery call to see if it's a good match
- [https://calendly.com/javidjamae/15-min-discovery-call](https://calendly.com/javidjamae/15-min-discovery-call)

## What This Is

This is an 800+ page comprehensive reference designed to be fed into your vibe coding tool (Cursor, Copilot, Claude, etc.). It gives your AI assistant ALL the context it needs to implement a production‑ready Stripe integration for SaaS applications.

You can absolutely read it linearly like a course, but its primary purpose is to act as a complete reference corpus for your AI coding assistant so it can generate accurate, production-quality code and guidance for complex billing scenarios.

## How To Use With Vibe Coding Tools

- Feed the individual Markdown modules (01-*.md, 02-*.md, …) into your AI tool as needed, or
- Generate a single merged Markdown file (and optional PDF) and supply that single artifact to your AI tool.

See “Generate a Single File or PDF” below to create a merged artifact.

## Why This Reference Is Different

This isn't just another Stripe tutorial. This course is based on actual production code that handles:
- Complex upgrade/downgrade flows with proration
- Annual vs monthly billing with interval changes
- Scheduled plan changes and cancellation flows
- Advanced webhook handling with idempotency
- Comprehensive E2E testing with real Stripe data
- Customer portal integration (both hosted and custom)
- Multi-tenant architecture with proper user isolation

## Prerequisites

- **Intermediate JavaScript/TypeScript** - Comfortable with async/await, promises, and modern JS
- **React/Next.js Experience** - Basic understanding of React hooks and Next.js API routes
- **Database Knowledge** - Understanding of SQL, migrations, and database relationships
- **API Integration Experience** - Familiar with REST APIs and webhook concepts
- **Testing Fundamentals** - Basic knowledge of unit testing and integration testing

## Course Structure

### **Module 1: Foundation & Architecture**
*Core patterns and architectural decisions*

- **01-stripe-fundamentals.md** - Core Stripe concepts, objects, and relationships
- **02-environment-setup.md** - Environment variables, test vs live mode, and security
- **03-database-design.md** - Database schema for subscriptions, plans, and user data
- **04-api-architecture.md** - API route structure and authentication patterns

### **Module 2: Basic Integration**
*Getting your first Stripe integration working*

- **05-checkout-sessions.md** - Creating and handling checkout sessions
- **06-webhook-fundamentals.md** - Basic webhook setup and signature verification
- **07-subscription-creation.md** - Processing completed checkouts and creating subscriptions
- **08-customer-management.md** - Creating and managing Stripe customers

### **Module 3: Plan Management**
*Implementing flexible pricing and plan structures*

- **09-plan-configuration.md** - Designing flexible plan structures with price IDs
- **10-pricing-pages.md** - Building dynamic pricing pages from plan data
- **11-plan-validation.md** - Validating plan changes and business rules
- **12-feature-gating.md** - Implementing plan-based feature access

### **Module 4: Advanced Subscription Management**
*Upgrades, downgrades, and proration*

- **13-upgrade-flows.md** - Immediate upgrades with proration handling
- **14-downgrade-flows.md** - Scheduled downgrades and end-of-period changes
- **15-proration-calculations.md** - Understanding and previewing proration amounts
- **16-interval-changes.md** - Monthly ↔ Annual billing interval changes
- **17-scheduled-changes.md** - Managing complex scheduled plan changes

### **Module 5: Billing Intervals & Complex Flows**
*Annual billing and complex upgrade scenarios*

- **18-annual-billing.md** - Implementing annual billing with proper discounting
- **19-mixed-upgrades.md** - Complex scenarios like "Pro Annual → Scale Monthly"
- **20-cancellation-flows.md** - Cancellation, reactivation, and grace periods
- **21-subscription-schedules.md** - Using Stripe Subscription Schedules effectively

### **Module 6: Customer Experience**
*Customer-facing billing interfaces*

- **22-customer-portal.md** - Stripe Customer Portal vs custom interfaces
- **23-billing-dashboards.md** - Building comprehensive billing dashboards
- **24-usage-tracking.md** - Implementing usage-based billing components
- **25-payment-methods.md** - Managing payment methods and failed payments

### **Module 7: Webhook Mastery**
*Bulletproof webhook handling*

- **26-webhook-security.md** - Advanced signature verification and security
- **27-webhook-reliability.md** - Idempotency, retries, and error handling
- **28-webhook-testing.md** - Testing webhook handlers thoroughly
- **29-webhook-monitoring.md** - Monitoring webhook health and debugging failures

### **Module 8: Testing Strategies**
*Comprehensive testing for billing systems*

- **30-unit-testing.md** - Testing billing logic and business rules
- **31-integration-testing.md** - Testing with real Stripe test data
- **32-e2e-testing.md** - End-to-end testing with Cypress and Stripe
- **33-test-data-management.md** - Managing test customers and subscriptions
- **34-testing-webhooks.md** - Testing webhook handlers and failure scenarios

### **Module 9: Production Deployment**
*Taking your billing system live safely*

- **35-production-checklist.md** - Pre-launch checklist and validation
- **36-environment-management.md** - Managing test vs production environments
- **37-monitoring-setup.md** - Setting up billing monitoring and alerts
- **38-security-hardening.md** - Security best practices for production

### **Module 10: Advanced Topics**
*Expert-level patterns and edge cases*

- **39-multi-tenancy.md** - Implementing multi-tenant billing architectures
- **40-tax-handling.md** - Handling taxes with Stripe Tax
- **41-coupons-discounts.md** - Implementing coupons and promotional pricing
- **42-failed-payments.md** - Handling failed payments and dunning management
- **43-compliance.md** - PCI compliance, data retention, and privacy

### **Module 11: Troubleshooting & Operations**
*Handling real-world issues and edge cases*

---

## Generate a Single File or PDF

Use the provided shell script to merge all modules into a single Markdown file. The merged file is ideal for feeding into AI tools that perform best with one large context file.

Requirements:
- Node.js (for optional PDF generation via md-to-pdf)

Steps:
1. Run the merge script from the repo root:
   ```bash
   ./merge-course.sh
   ```
2. The merged Markdown will be created at:
   ```
   generated/merged-stripe-course.md
   ```
3. (Optional) Convert to PDF:
   ```bash
   cd generated && npx md-to-pdf merged-stripe-course.md
   ```

Notes:
- The `generated/` directory is git-ignored.
- The script also appends the README and inserts clear module separators.

---

## Use This Repo As a Git Subtree (Recommended)

If you want to keep this reference close to your app code (and easily pull upstream updates), consider adding it as a Git subtree inside your product repository.

Replace values in angle brackets with your own choices:

- `<REF_REPO_URL>`: The URL of this repo (e.g., `git@github.com:your-org/stripe-vibe-coding-companion.git`)
- `<PREFIX_PATH>`: Where you want it to live inside your app repo (e.g., `docs/stripe-vibe-coding-companion`)
- `<BRANCH>`: The branch to track (e.g., `main`)

Add as a subtree:
```bash
git remote add stripe-vibe <REF_REPO_URL>
git fetch stripe-vibe
git subtree add --prefix=<PREFIX_PATH> stripe-vibe <BRANCH> --squash
```

Pull upstream updates later:
```bash
git fetch stripe-vibe
git subtree pull --prefix=<PREFIX_PATH> stripe-vibe <BRANCH> --squash
```

Push your changes back upstream (if you maintain a fork):
```bash
git subtree push --prefix=<PREFIX_PATH> stripe-vibe <BRANCH>
```

Tips:
- Subtree commits are regular commits inside your app repo; no special tooling needed for consumers.
- Use `--squash` if you prefer a cleaner history in your app repo.

- **44-common-issues.md** - Common Stripe integration issues and solutions
- **45-debugging-techniques.md** - Tools and techniques for debugging billing issues
- **46-data-reconciliation.md** - Keeping your database in sync with Stripe
- **47-migration-patterns.md** - Migrating existing customers to new pricing
- **48-performance-optimization.md** - Optimizing API calls and database queries

## Learning Path Recommendations

### **Quick Start Path** (Essential for MVP)
Modules 1-3 + 5 + 7 (basics) + 9 (production)
*Estimated time: 2-3 weeks*

### **Production-Ready Path** (Recommended for most teams)  
All modules except advanced topics (Modules 1-9)
*Estimated time: 4-6 weeks*

### **Complete Mastery Path** (For billing-critical applications)
All modules including advanced topics
*Estimated time: 6-8 weeks*

## Key Learning Outcomes

By the end of this course, you'll be able to:

✅ **Implement complex subscription flows** with confidence  
✅ **Handle proration and billing edge cases** correctly  
✅ **Build bulletproof webhook handlers** with proper error handling  
✅ **Test billing systems comprehensively** including E2E scenarios  
✅ **Deploy billing systems safely** to production  
✅ **Debug and troubleshoot** billing issues effectively  
✅ **Handle customer billing inquiries** with deep system knowledge  
✅ **Implement advanced features** like usage billing and tax handling  

## Code Examples & Patterns

Throughout this course, you'll see real production code patterns including:

- **TypeScript interfaces** for type-safe billing operations
- **Database schemas** with proper relationships and constraints
- **API route handlers** with comprehensive error handling
- **React components** for billing UIs and customer portals
- **Test suites** covering unit, integration, and E2E scenarios
- **Webhook handlers** with idempotency and retry logic
- **Utility functions** for common billing calculations

## Prerequisites Checklist

Before starting, ensure you have:

- [ ] **Stripe account** (test mode is sufficient to start)
- [ ] **Next.js development environment** set up
- [ ] **Database access** (PostgreSQL recommended)
- [ ] **Basic TypeScript knowledge**
- [ ] **Testing framework familiarity** (Jest, Cypress)
- [ ] **API integration experience**

## Getting Help

- **Code Examples**: Each module includes complete, tested code examples
- **Common Issues**: Troubleshooting sections address frequent problems  
- **Best Practices**: Learn from production-tested patterns
- **Testing Strategies**: Comprehensive test coverage examples

---

**Ready to build bulletproof billing systems?** Start with Module 1: Stripe Fundamentals.
