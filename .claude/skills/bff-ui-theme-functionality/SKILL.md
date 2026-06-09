---
name: bff-ui-theme-functionality
description: Use this when designing, reviewing, debugging, or modifying Drone or Overmind UI theme, layout, Bootstrap styling, responsive design, navbar/header structure, icons, links, tables, pagination, filters, logging UI, dropdown checkboxes, or shared UI behavior.
---

# Batocera Fleet Federation UI Theme and Functionality Skill

## Goal

Ensure Drone and Overmind share the same UI theme, look, feel, layout conventions, and behavior.

Drone and Overmind should feel like two parts of the same product. UI work should prioritize consistency, mobile friendliness, responsive design, readable pages, predictable navigation, and efficient data loading.

## Project Context

The Batocera Fleet Federation system has two primary UI surfaces:

- **Overmind**: central web UI for users, drones, approvals, swarm management, ROM metadata, sync state, roles, invites, and administration.
- **Drone**: Batocera-side local UI for machine status, local ROMs, saves/configs, pairing, sync, connectivity, and diagnostics.

Both UIs should use the same visual language, layout rules, components, navigation structure, and behavior patterns.

Prefer Bootstrap for layout and components unless the existing project clearly uses another established framework.

## Core UI Principles

When working on Drone or Overmind UI changes, follow these rules:

1. Keep Drone and Overmind visually consistent.
2. Prefer shared theme variables, shared CSS, shared templates, or duplicated conventions where sharing is not practical.
3. Use Bootstrap components and layout utilities where reasonable.
4. Design mobile-first and ensure pages are responsive.
5. Avoid UI patterns that require desktop-width screens.
6. Use pagination for large data sets.
7. Do not pull large datasets into the UI when paged data is appropriate.
8. Keep common navigation, links, icons, and headers in the same format across Drone and Overmind.
9. Prefer dropdown checkboxes over large visible checkbox groups.
10. Make tables readable on mobile.
11. Make logging views dense, readable, and easy to scan.
12. Keep behavior consistent across similar pages.
13. Avoid one-off styling unless there is a clear product reason.
14. Do not introduce a new UI framework without explicit approval.

## Shared Theme Rules

Drone and Overmind should share the same theme concepts:

- color palette,
- font choices,
- spacing,
- border radius,
- button styles,
- card styles,
- table styles,
- navbar/header layout,
- icon usage,
- link styling,
- alert/toast styling,
- badge/status colors,
- form control styling,
- modal styling,
- log viewer styling.

Prefer centralizing theme values in one place where possible.

Examples:

```text
static/css/theme.css
static/css/bff-theme.css
templates/components/navbar.html
templates/components/header.html
templates/components/pagination.html
templates/components/log-viewer.html
```

Mirror the same structure and names so behavior remains consistent.

## Bootstrap Rules

Prefer Bootstrap for:

- responsive grid layout,
- navbars,
- buttons,
- cards,
- badges,
- dropdowns,
- modals,
- forms,
- tables,
- pagination,
- alerts,
- accordions,
- offcanvas mobile menus,
- utility classes.

Use Bootstrap utilities before creating custom CSS.

Avoid excessive custom layout CSS when Bootstrap can solve it.

Custom CSS is acceptable for product-specific theme polish, log viewers, compact tables, and shared BFF visual identity.

## Responsive Design Rules

Every page should work well on:

- mobile phones,
- tablets,
- desktop screens,
- local Batocera browser contexts,
- remote browser access.

Use responsive Bootstrap patterns:

```html
<div class="table-responsive">
  <table class="table table-sm align-middle">
    ...
  </table>
</div>
```

Use responsive spacing:

```html
<div class="d-flex flex-column flex-md-row gap-2 align-items-md-center justify-content-between">
  ...
</div>
```

Use mobile-friendly actions:

```html
<div class="btn-group w-100 w-md-auto">
  ...
</div>
```

Avoid:

- fixed-width layouts,
- wide tables without horizontal scrolling,
- hidden critical actions on mobile,
- tiny tap targets,
- large checkbox groups,
- navbars that wrap unpredictably,
- modals that are unusable on small screens.

## Pagination and Data Loading Rules

Always favor paging in UI instead of pulling large amounts of data.

Default page size options should be:

```text
50
100
200
```

For large collections, never load everything by default.

Large collections include:

- ROMs,
- saves,
- config files,
- logs,
- drones,
- peer connectivity records,
- sync jobs,
- sync job items,
- audit events,
- transfer attempts,
- scan results,
- user activity,
- API events.

Required UI behavior for large lists:

1. Use server-side pagination.
2. Provide page size selector.
3. Provide deterministic sorting.
4. Provide filters/search where useful.
5. Preserve filter state across page changes.
6. Avoid fetching all rows and filtering in the browser.
7. Avoid rendering thousands of DOM rows.
8. Show result count when available.
9. Show loading and empty states.
10. Keep pagination controls consistent across Drone and Overmind.

Preferred pagination control:

```html
<div class="d-flex flex-column flex-md-row gap-2 align-items-md-center justify-content-between">
  <div class="text-muted small">
    Showing {{ start }}-{{ end }} of {{ total }}
  </div>

  <div class="d-flex gap-2 align-items-center">
    <select class="form-select form-select-sm" name="page_size">
      <option value="50">50</option>
      <option value="100">100</option>
      <option value="200">200</option>
    </select>

    <nav aria-label="Pagination">
      <ul class="pagination pagination-sm mb-0">
        ...
      </ul>
    </nav>
  </div>
</div>
```

## Navbar, Header, Links, and Icons

Navbar, links, icons, and headers should be created with the same format across Drone and Overmind.

Use a shared structure:

```text
brand area
primary nav links
status/health indicators
help/docs/API/GitHub icons where applicable
user/account/logout area where applicable
```

Preferred navbar pattern:

```html
<nav class="navbar navbar-expand-lg bff-navbar">
  <div class="container-fluid">
    <a class="navbar-brand d-flex align-items-center gap-2" href="/">
      <span class="bff-brand-icon">{ }</span>
      <span class="bff-brand-text">Batocera Overmind</span>
    </a>

    <button
      class="navbar-toggler"
      type="button"
      data-bs-toggle="collapse"
      data-bs-target="#mainNavbar"
      aria-controls="mainNavbar"
      aria-expanded="false"
      aria-label="Toggle navigation">
      <span class="navbar-toggler-icon"></span>
    </button>

    <div class="collapse navbar-collapse" id="mainNavbar">
      <ul class="navbar-nav me-auto mb-2 mb-lg-0">
        <li class="nav-item">
          <a class="nav-link" href="/drones">
            <i class="bi bi-hdd-network"></i>
            <span>Drones</span>
          </a>
        </li>
      </ul>

      <div class="d-flex align-items-center gap-2">
        <a class="btn btn-sm btn-outline-secondary" href="/help" title="Help">
          <i class="bi bi-question-circle"></i>
        </a>
        <a class="btn btn-sm btn-outline-secondary" href="/docs" title="API Docs">
          <i class="bi bi-braces"></i>
        </a>
      </div>
    </div>
  </div>
</nav>
```

Drone can use the same structure with Drone-specific brand text:

```text
Batocera Drone
```

Overmind can use:

```text
Batocera Overmind
```

Do not create unrelated nav/header layouts between Drone and Overmind.

## Page Header Rules

Every major page should have a consistent header.

Preferred page header pattern:

```html
<div class="bff-page-header d-flex flex-column flex-md-row gap-2 align-items-md-center justify-content-between mb-3">
  <div>
    <h1 class="h4 mb-1">Page Title</h1>
    <div class="text-muted small">Short page description or status summary.</div>
  </div>

  <div class="d-flex gap-2 flex-wrap">
    <button class="btn btn-sm btn-primary">Primary Action</button>
    <button class="btn btn-sm btn-outline-secondary">Secondary Action</button>
  </div>
</div>
```

Use the same hierarchy across Drone and Overmind:

```text
h1/h4 page title
small muted description
right-side action group
status badges when useful
```

## Icon Rules

Use a consistent icon library.

Preferred option:

```text
Bootstrap Icons
```

Use icons consistently:

- same icon for same concept,
- icons should support text, not replace it unless space-constrained,
- include accessible labels or titles for icon-only buttons,
- do not mix unrelated icon sets without a reason.

Example:

```html
<a class="btn btn-sm btn-outline-secondary" href="/logs" title="Logs" aria-label="Logs">
  <i class="bi bi-journal-text"></i>
</a>
```

## Forms and Filters

Use Bootstrap form controls.

For large filter sets, prefer dropdown checkboxes instead of visible checkbox groups.

Avoid:

```html
<div>
  <label><input type="checkbox"> NES</label>
  <label><input type="checkbox"> SNES</label>
  <label><input type="checkbox"> Genesis</label>
  ...
</div>
```

Prefer:

```html
<div class="dropdown">
  <button class="btn btn-sm btn-outline-secondary dropdown-toggle" type="button" data-bs-toggle="dropdown">
    Systems
  </button>

  <div class="dropdown-menu p-2 bff-filter-dropdown">
    <label class="dropdown-item">
      <input class="form-check-input me-2" type="checkbox" name="systems" value="nes">
      NES
    </label>
    <label class="dropdown-item">
      <input class="form-check-input me-2" type="checkbox" name="systems" value="snes">
      SNES
    </label>
  </div>
</div>
```

Dropdown checkbox rules:

1. Use for multi-select filters.
2. Keep them searchable when the list is large.
3. Show selected count in the dropdown button.
4. Preserve selected values across pagination.
5. Avoid making users scroll through huge visible checkbox groups.

Example button label:

```text
Systems (4 selected)
```

## Table Rules

Tables should be compact, readable, and responsive.

Preferred table wrapper:

```html
<div class="table-responsive">
  <table class="table table-sm table-hover align-middle bff-table">
    <thead>
      <tr>
        ...
      </tr>
    </thead>
    <tbody>
      ...
    </tbody>
  </table>
</div>
```

For large tables:

1. Use pagination.
2. Use compact rows.
3. Keep action buttons grouped.
4. Avoid too many columns on mobile.
5. Hide less important columns on small screens using responsive utility classes.
6. Use badges for status.
7. Use deterministic sorting.
8. Avoid rendering thousands of rows.

Example responsive column:

```html
<td class="d-none d-lg-table-cell">{{ last_seen_at }}</td>
```

## Logging UI Rules

Any logging UI element should use a smaller font that is easier to read through large numbers of logs.

Logging UI should be dense, readable, searchable, and scrollable.

Preferred log viewer style:

```css
.bff-log-viewer {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
  font-size: 0.78rem;
  line-height: 1.35;
  white-space: pre-wrap;
  word-break: break-word;
  max-height: 65vh;
  overflow: auto;
  padding: 0.75rem;
  border-radius: 0.5rem;
}
```

Log UI rules:

1. Use smaller monospace font.
2. Preserve line breaks.
3. Allow scrolling.
4. Avoid huge DOM rendering.
5. Use pagination or streaming for large logs.
6. Provide filters for level, component, and text search where useful.
7. Highlight severity consistently.
8. Do not make log rows overly tall.
9. Avoid giant cards for each log line.
10. Avoid loading unbounded logs into the browser.

Preferred log page controls:

```text
level filter
component filter
search text
page size 50/100/200
refresh button
auto-refresh toggle
download/export button when appropriate
```

For logs, page size may use:

```text
100
200
500
```

Only use larger sizes when the UI remains responsive.

## Cards and Status UI

Use cards for grouped summaries.

Preferred status card pattern:

```html
<div class="card bff-card">
  <div class="card-body">
    <div class="d-flex align-items-center justify-content-between">
      <div>
        <div class="text-muted small">Status</div>
        <div class="h5 mb-0">Online</div>
      </div>
      <span class="badge text-bg-success">Healthy</span>
    </div>
  </div>
</div>
```

Use consistent badge language:

```text
Online
Offline
Healthy
Warning
Error
Pending
Approved
Denied
Syncing
Complete
Failed
Unknown
```

## Button Rules

Use Bootstrap button styles consistently.

Preferred meanings:

```text
btn-primary: main action
btn-secondary: neutral action
btn-outline-secondary: secondary navigation/action
btn-success: positive completion action
btn-warning: caution action
btn-danger: destructive action
btn-link: low-emphasis link action
```

Destructive actions should be clear and preferably confirmed.

Avoid using different button colors for the same action across Drone and Overmind.

## Behavior Consistency Rules

Similar pages should behave the same way across Drone and Overmind.

Examples:

- list pages use the same pagination layout,
- filters are in the same location,
- search behaves the same way,
- action buttons appear in the same column/location,
- status badges use the same labels,
- log viewers use the same font/size,
- navbars have the same structure,
- page headers have the same format,
- empty states look the same,
- loading states look the same.

If creating a new UI pattern, consider whether both Drone and Overmind should use it.

## Mobile-Friendly Rules

Mobile UI should:

1. Use stacked layouts.
2. Keep tap targets large enough.
3. Collapse navbar cleanly.
4. Avoid horizontal overflow except inside intentional table wrappers.
5. Hide low-priority columns on small screens.
6. Keep actions accessible.
7. Avoid giant modals.
8. Keep filter controls usable.
9. Avoid checkbox walls.
10. Prefer dropdowns, accordions, and offcanvas menus where useful.

Test layouts at:

```text
375px width
768px width
1024px width
desktop width
```

## Empty, Loading, and Error States

Every major UI list should have clear states.

Empty state:

```html
<div class="text-center text-muted py-4">
  <div class="mb-2">
    <i class="bi bi-inbox"></i>
  </div>
  <div>No records found.</div>
</div>
```

Loading state:

```html
<div class="d-flex align-items-center gap-2 text-muted">
  <div class="spinner-border spinner-border-sm" role="status"></div>
  <span>Loading...</span>
</div>
```

Error state:

```html
<div class="alert alert-danger">
  Unable to load data. Try again or check logs.
</div>
```

Use the same patterns across Drone and Overmind.

## Accessibility Rules

UI should remain accessible.

Follow these rules:

1. Use semantic HTML.
2. Add `aria-label` for icon-only buttons.
3. Ensure form labels exist.
4. Ensure dropdowns are keyboard usable.
5. Do not rely on color alone for status.
6. Keep contrast readable.
7. Use meaningful link text.
8. Ensure navbar toggles have labels.
9. Keep focus states visible.
10. Avoid tiny controls.

## Performance Rules

UI changes should avoid unnecessary browser and API load.

Do not:

- fetch all records and paginate in JavaScript,
- render thousands of rows,
- load large logs all at once,
- use excessive client-side polling,
- create expensive page load queries,
- add heavy frontend dependencies without approval,
- make UI pages wait on full filesystem scans,
- make UI pages wait on full ROM inventory refreshes.

Prefer:

- server-side pagination,
- server-side filtering,
- summary endpoints,
- lightweight cards,
- cached status,
- background refresh jobs,
- incremental loading,
- compact table rows.

## Common UI Components to Standardize

Standardize these across Drone and Overmind:

- navbar,
- brand/header,
- icon buttons,
- page header,
- status cards,
- badges,
- pagination controls,
- page-size selector,
- table wrapper,
- empty state,
- loading state,
- error state,
- filter bar,
- dropdown checkbox filter,
- log viewer,
- confirmation modal,
- toast/alert messages,
- mobile menu behavior.

## Suggested Shared CSS

Use a shared CSS file or mirrored CSS between projects.

Example:

```css
:root {
  --bff-radius: 0.65rem;
  --bff-page-max-width: 1440px;
}

.bff-page {
  max-width: var(--bff-page-max-width);
  margin: 0 auto;
}

.bff-card {
  border-radius: var(--bff-radius);
}

.bff-page-header {
  border-bottom: 1px solid rgba(0, 0, 0, 0.075);
  padding-bottom: 0.75rem;
}

.bff-table {
  font-size: 0.9rem;
}

.bff-filter-dropdown {
  min-width: 16rem;
  max-height: 20rem;
  overflow: auto;
}

.bff-log-viewer {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
  font-size: 0.78rem;
  line-height: 1.35;
  white-space: pre-wrap;
  word-break: break-word;
  max-height: 65vh;
  overflow: auto;
  padding: 0.75rem;
  border-radius: var(--bff-radius);
}
```

Do not hardcode a completely separate visual style in Drone and Overmind.

## Review Checklist

When reviewing UI changes, verify:

- Does Drone still look consistent with Overmind?
- Does Overmind still look consistent with Drone?
- Is Bootstrap used where appropriate?
- Is the page mobile-friendly?
- Does the navbar follow the shared format?
- Do links, icons, and headers follow the shared format?
- Are large lists paginated?
- Are page size options 50/100/200 where applicable?
- Are large datasets filtered/paged server-side?
- Are dropdown checkboxes used instead of large checkbox groups?
- Are logs displayed with compact readable font?
- Are tables responsive?
- Are actions usable on mobile?
- Are empty/loading/error states present?
- Are statuses shown consistently?
- Are unnecessary custom styles avoided?
- Are new UI constructs reusable across both apps?

## Common Failure Patterns

Look for these first:

- Drone and Overmind have different navbar layouts.
- Drone and Overmind use different button/status styles.
- One app uses cards while the other uses plain lists for the same concept.
- UI fetches every ROM or log entry at once.
- Pagination exists in the frontend only after fetching all data.
- Checkbox groups take over the page.
- Logs use large font or one-card-per-line layout.
- Tables overflow mobile screens.
- Icon-only buttons have no labels.
- Filters reset unexpectedly when changing pages.
- Page-size behavior differs between Drone and Overmind.
- New CSS is page-specific when it should be shared.
- Desktop layout works but mobile is broken.

## Search Rules for Large Data Sets

For large data set UIs, prefer a search textbox with an explicit Search button.

Large searchable data sets include:

- ROMs
- saves
- config files
- logs
- drones
- peer connectivity records
- sync jobs
- sync job items
- audit events
- transfer attempts
- scan results
- user activity
- API events

Preferred pattern:

```html
<form method="get" class="d-flex flex-column flex-md-row gap-2 align-items-md-center">
  <input
    type="search"
    name="q"
    class="form-control form-control-sm"
    placeholder="Search..."
    value="{{ q }}"
    aria-label="Search">

  <button type="submit" class="btn btn-sm btn-primary">
    Search
  </button>

  <a href="{{ clear_url }}" class="btn btn-sm btn-outline-secondary">
    Clear
  </a>
</form>
```

Search behavior rules:

1. Prefer server-side search for large data sets.
2. Do not fetch all rows and search in the browser.
3. Use an explicit Search button instead of triggering expensive searches on every keystroke.
4. Preserve search text across pagination.
5. Preserve filters across search.
6. Reset to the first page when a new search is submitted.
7. Use indexed fields where possible.
8. Add database indexes that support common search/filter patterns.
9. Show empty states when no results match.
10. Keep search layout consistent between Drone and Overmind.

Live search may be used only for small local lists or when debounce, cancellation, and server-side limits are implemented.

## Expected Output Format

When completing UI work, respond using this format:

```text
Root cause / objective:
...

Theme/look-and-feel changes:
...

Shared Drone/Overmind consistency changes:
...

Navbar/header/link/icon changes:
...

Responsive/mobile changes:
...

Pagination/data-loading changes:
...

Filter/dropdown checkbox changes:
...

Logging UI changes:
...

Bootstrap usage:
...

Validation:
...

Risks:
...

Files changed:
...
```

## Safety Rules

Do not:

- introduce a new frontend framework without explicit approval,
- create inconsistent themes between Drone and Overmind,
- fetch large datasets into the browser,
- render thousands of rows,
- use visible checkbox groups for large filter sets,
- make log views overly large or hard to scan,
- create unrelated navbars,
- hide critical actions on mobile,
- break existing routes,
- remove accessibility labels,
- use icon-only controls without `aria-label` or title,