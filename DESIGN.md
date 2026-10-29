# Oxidized Web Design System

## Design philosophy

Oxidized Web is an operations console for engineers who need to scan device state, backup history, and configuration changes quickly. Use a compact, data-first composition inspired by fintech trading dashboards: strong numeric hierarchy, quiet surfaces, precise status colors, and high-density tables. Network telemetry must come from Oxidized or Git; unavailable values stay explicitly unavailable. This design adapts the reference direction to the existing Sinatra, Haml, Bootstrap, CSS, and JavaScript architecture.

The requested Fintech skill page (`https://skillsui.app/skills/fintech`) was not reachable from the available browser tool and no local Fintech `SKILL.md` was installed. This system records the accessible project design guidance and the requested fintech visual qualities without claiming that the unavailable skill itself was applied.

## Color tokens

`lib/oxidized/web/public/css/oxidized.css` defines the palette as the single CSS source of truth. Templates and components use these variables rather than adding page-specific colors.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| Canvas | `#F5F7FB` | `#0B1020` | Application workspace |
| Surface | `#FFFFFF` | `#141D30` | Cards, tables, forms, dialogs |
| Muted surface | `#EEF1F7` | `#1B2740` | Headers, controls, selected rows |
| Navigation | `#10172A` | `#070B16` | Sidebar rail |
| Navigation active | `#252D4B` | `#252D4B` | Active sidebar item |
| Primary / focus | `#5146D8` | `#938AFF` | Primary actions, links, focus, selected tabs |
| Primary hover | `#4035B8` | `#A9A2FF` | Hovered primary actions |
| Primary contrast | `#FFFFFF` | `#0B1020` | Text on primary buttons |
| Primary tint | `#EAE8FC` | `#29264F` | Selected and focus related surfaces |
| Secondary | `#0E7490` | `#40CFE0` | Secondary information |
| Info | `#06B6D4` | `#40CFE0` | Informational indicators |
| Success | `#0C7F70` | `#33C7AB` | Successful backup only |
| Success surface | `#FFFFFF` | `#163A36` | Successful status icon and badge surface |
| Failure | `#C13E58` | `#FF708B` | Failed backup and destructive actions |
| Failure surface | `#FFFFFF` | `#432431` | Failure status icon and badge surface |
| Warning | `#A0610A` | `#F4BD65` | Warnings and pending states |
| Warning surface | `#FFFFFF` | `#40331F` | Warning status icon and badge surface |
| Text | `#182237` | `#E8EDF8` | Main copy |
| Muted text | `#596780` | `#A6B5CD` | Supporting copy |
| Border | `#DDE5F0` | `#2E3A52` | Component separation |

Status colors only convey their named semantic state. Dashboard metric cards retain neutral surfaces, with semantic color limited to icons and subtle indicators. Distinct vendor marks may use vendor brand colors as an explicit identity exception; they never indicate health or backup status. Charts use palette tokens and labeled legends. Never infer success from missing data. Text, controls, status text, and focus indicators must maintain WCAG 2.2 AA contrast in both themes; labels and symbols supplement color for every state.

## Typography

Use the system UI sans-serif stack for navigation and prose. Use the system monospace stack for configuration, addresses when useful, and exact revision data. Use tabular numerals for counters and timestamps. Page titles are compact and semibold; ordinary copy stays at least 12px, table data at least 11px, and labels may use 10px when accompanied by a clear value.

## Spacing and grid

Base spacing is 4px, with common increments of 8, 12, 16, and 24px. Use a 224px expanded sidebar and 68px collapsed rail. The header is 56px on desktop. Content uses 16–20px desktop insets and 10–12px on small screens. KPI panels target 84–100px, controls 34–38px, and rows 38–42px. Desktop dashboard columns use a flexible two-column grid; collapse charts and secondary panels before the device table becomes unreadable.

## Navigation

Use grouped, collapsible Overview, Backups, Devices, and Administration sections. Only implemented routes appear. The active link uses the muted navigation surface and Indigo Violet edge marker. Keep labels visible in expanded mode; collapsed links expose tooltips and accessible names. Mobile navigation is a keyboard-accessible drawer with Escape and outside-click dismissal. Persist desktop collapse preference only.

## Buttons and interaction

Primary buttons use Indigo Violet with white text; secondary buttons use a quiet surface and border. Destructive actions use Raspberry and require a confirmation step. Controls have a 6–8px radius, compact height, visible keyboard focus, and a short 140–180ms hover/focus transition. Avoid gratuitous animation. Honor `prefers-reduced-motion`.

## Forms

Use visible, concise labels above 34–38px controls. Group related connection fields in a responsive grid. Use inline validation close to the field, a clear form-level error summary, and a visible loading/disabled state only when an operation is actually in progress. Credentials are write-only after saving and never repopulated in edit forms. If the configured source cannot safely accept writes, replace the form with a read-only explanation and actionable source-mapping guidance.

## Cards and shadows

Cards use a surface, a fine border, 9–10px radius, and a restrained shadow. KPI cards use a narrow semantic color rail and a small tinted icon surface rather than full saturated backgrounds. Reserve gradients for small chart fills and selected accents. Avoid empty panels and oversized padding.

## Tables

Use sticky muted headers, compact 38–42px rows, tabular numbers, clear row hover feedback, and distinct status pills. Keep horizontal scrolling inside a table wrapper, not on the page. At small viewports, prioritize name, state, last successful backup, and actions. Make actions visibly labeled or provide accessible names; never rely on an unlabeled tiny icon.

## Charts

Donut and activity charts must be derived from available Oxidized/Git data. Place a concise title and data window beside the chart. Legends wrap into two columns on phones and retain readable labels. When no historical activity exists, show an honest empty state instead of a fabricated trend.

## Configuration comparison

Use a compact sticky selector row, visible revision IDs and timestamps, and side-by-side monospace panes on wide screens. Use a neutral background for unchanged lines, Emerald additions, and Raspberry removals. Keep line numbers and bounded scroll regions. Stack panes below 768px and offer unified comparison on narrow screens. Preserve the underlying Git history exactly.

## Borders and depth

Use one-pixel borders with token colors. Standard radius is 6–10px; larger dialog radius may reach 14px. Shadows should define elevation only: small panels use a 1–4px soft shadow; menus/dialogs use a larger, diffuse shadow. Avoid high-contrast outlines around every component.

## Responsive breakpoints

Use the existing Bootstrap-aligned breakpoints: 1200px, 992px, 768px, 576px, and 480px. At 992px the sidebar becomes a drawer. At 768px dashboard panels and diff panes stack. At 480px forms become one column, toolbars wrap, and chart legends remain readable. The page must have no horizontal overflow; table and code overflow stays inside their own containers.

## Dark mode

Dark mode changes canvas, surfaces, borders, text, and status tints through CSS custom properties. Preserve contrast for controls, diff lines, disabled states, and warning panels. Vendor marks may retain their local white logo tiles for legibility. Both themes must communicate identical data and action affordances.

## State styling and accessibility

Every interactive element supports keyboard focus with a visible outline. Use semantic links and buttons, accessible labels, `aria-live` only for meaningful action results, and sufficient text contrast. Loading, empty, disabled, error, and success states have distinct language and styling. Reduced motion suppresses transitions and counters. Never show an epoch placeholder or infer unsupported metadata.

## Visual validation targets

Validate Dashboard, Device Management, Configuration History, Diff Viewer, Login, and User Management at 1920×1080, 1440×900, 1366×768, 1024×768, 768×1024, and 390×844. At each size check page-level overflow, navigation, button placement, chart fit, readable table actions, and diff-pane behavior.
