<!--
  Vendored from gotalab/cc-sdd v3.0.2 (https://github.com/gotalab/cc-sdd.git)
  Source path: tools/cc-sdd/templates/shared/settings/templates/steering/structure.md | Materialized: 2026-05-26T19:52:37.629907+00:00
  Do not edit; bump dfetch.yaml and run vendor:materialize.
-->

# Project Structure

## Organization Philosophy

[Describe approach: feature-first, layered, domain-driven, etc.]

## Directory Patterns

### [Pattern Name]
**Location**: `/path/`  
**Purpose**: [What belongs here]  
**Example**: [Brief example]

### [Pattern Name]
**Location**: `/path/`  
**Purpose**: [What belongs here]  
**Example**: [Brief example]

## Naming Conventions

- **Files**: [Pattern, e.g., PascalCase, kebab-case]
- **Components**: [Pattern]
- **Functions**: [Pattern]

## Import Organization

```typescript
// Example import patterns
import { Something } from '@/path'  // Absolute
import { Local } from './local'     // Relative
```

**Path Aliases**:
- `@/`: [Maps to]

## Code Organization Principles

[Key architectural patterns and dependency rules]

---
_Document patterns, not file trees. New files following patterns shouldn't require updates_
