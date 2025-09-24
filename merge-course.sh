#!/bin/bash

# Stripe Implementation Course Merger
# Merges all course modules into a single comprehensive document

# Output directory and file name
output_dir="generated"
output="$output_dir/merged-stripe-course.md"

# Change to the script directory
cd "$(dirname "$0")"

# Create output directory if it doesn't exist
mkdir -p "$output_dir"

# Overwrite output file if it exists
> "$output"

# Add README first
echo "📚 Adding README.md to merged course..."
echo -e "\n\n\n---\n# COURSE README\n---\n" >> "$output"
cat "README.md" >> "$output"
echo "✅ Added README.md to merged course"

# Add header to merged file
cat << 'EOF' >> "$output"

---

# Complete Stripe Implementation Mastery Course

This document contains the complete Stripe implementation course, compiled from individual modules. Each module is separated by clear section headers.

**Course Overview**: This comprehensive course teaches you how to implement a production-ready Stripe integration for SaaS applications, based on battle-tested patterns from real-world implementations.

**Generated on**: $(date)

---

EOF

# Loop through all .md files in numerical order, excluding the output file and README
for f in $(ls [0-9][0-9]-*.md 2>/dev/null | sort -n); do
  if [[ "$f" != "$output" && "$f" != "README.md" ]]; then
    echo -e "\n\n\n---\n# MODULE: [$f]\n---\n" >> "$output"
    cat "$f" >> "$output"
    echo "✅ Added $f to merged course"
  fi
done

# Add footer
cat << 'EOF' >> "$output"

---

## Course Complete

You have completed the Stripe Implementation Mastery Course! This comprehensive guide covers:

- Stripe fundamentals and core concepts
- Environment setup and security best practices  
- Database design patterns for billing systems
- API architecture for subscription management
- Checkout sessions and payment processing
- Webhook handling and event processing
- Subscription lifecycle management
- Customer data management and synchronization

**Next Steps**:
1. Implement the patterns in your own application
2. Test thoroughly in Stripe's test mode
3. Set up monitoring and alerting
4. Deploy to production with confidence

**Support**: If you need help implementing these patterns, refer to the individual module files or consult the Stripe documentation.

---

*This course is based on production-tested patterns and real-world implementations.*
EOF

echo ""
echo "🎉 Course merger complete!"
echo "📄 Merged course written to: $output"
echo "📊 Total modules included: $(ls [0-9][0-9]-*.md 2>/dev/null | wc -l)"
echo ""
echo "To view the complete course:"
echo "  cat $output | less"
echo ""
echo "To convert to PDF (requires md-to-pdf):"
echo "  cd $output_dir && npx md-to-pdf merged-stripe-course.md"
