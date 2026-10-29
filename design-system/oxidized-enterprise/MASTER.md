# Oxidized Enterprise — NOC Design System

Generated from the `ui-ux-pro-max` design-system workflow for a dense, real-time network operations console. Adapted for the existing Sinatra/Haml/CSS application; no frontend framework or external runtime was added.

## Product direction

A compact Network Operations Center workspace that puts device health, backup state, recent changes, and actionable inventory in the first scan. Keep telemetry tied to real Core or Git data; label current-session state and show a truthful empty state when history is unavailable.

## Visual language

- **Workspace:** cool blue-gray canvas with quiet surface separation.
- **Navigation:** deep navy rail with compact grouped routes, clear active marker, and cyan/blue focus accent.
- **Action:** electric blue for primary action and selection; cyan for secondary technical emphasis.
- **Status:** emerald success, coral failure, amber attention, violet metadata. Status hues describe actual state and are not used decoratively.
- **Surfaces:** 1px border, 10px standard radius, low-elevation shadow. Reserve gradients for very small accents and charts; avoid glass effects on data panels.

## Color tokens

| Token | Light | Dark | Usage |
|---|---|---|---|
| Canvas | `#F1F5FB` | `#0B1220` | App workspace |
| Surface | `#FFFFFF` | `#111C2B` | Cards, tables, forms |
| Surface muted | `#F7F9FD` | `#162336` | Headers, inputs, quiet blocks |
| Sidebar | `#0F172A` | `#080F1C` | Navigation |
| Text | `#142136` | `#E8EEF7` | Main content |
| Muted text | `#66758C` | `#A6B3C5` | Supporting information |
| Border | `#D9E2EF` | `#29394F` | Dividers, input edges |
| Blue | `#2563EB` | `#72A0FF` | Primary actions, selection |
| Cyan | `#06B6D4` | `#22D3EE` | Network identity, chart series |
| Emerald | `#059669` | `#42D5A1` | Successful backup |
| Amber | `#B77910` | `#F5BD52` | Attention / unknown state |
| Coral | `#E5485B` | `#FF8292` | Failed backup / destructive action |
| Purple | `#7C3AED` | `#C4B5FD` | Secondary metadata |

## Density and layout

- Sidebar 224px expanded, 68px collapsed; mobile drawer below 992px.
- Top bar 56px desktop and 52px narrow mobile.
- Main page inset 16–20px desktop, 10–12px mobile.
- KPI cards 82–90px high; inventory rows 38px; controls 32–36px.
- Use 4/8/12/16/24px spacing increments. Keep body text at 13px or larger in ordinary page content; reserve 9–11px for labels and dense table metadata.
- Tables may scroll within their own wrapper, never at page level. Essential filters and actions wrap before they overlap.

## Type and data

Use system UI sans for navigation and prose; system monospace for configuration and exact device values. Use tabular numerals for counters and times. Keep titles compact and high-contrast, labels sentence-case, metadata muted. Do not invent vendor, firmware, or backup information.

## Components

- **KPI:** neutral surface with a narrow semantic status rail, small tinted icon tile, compact value and one-line definition. Avoid four full-bleed colored blocks.
- **Charts:** compact cards with direct title and source definition. Donut legends wrap to two columns on phones and remain operable filters. Historical trends appear only when backed by Git records.
- **Tables:** sticky muted header, 38px rows, subdued borders, visible vendor mark, semantic backup badge, and labeled actions. Keep horizontal overflow in `.table-responsive`.
- **Forms:** short labels, 35px inputs, grouped fields, inline validation, visible focus, and full-width submit only where it helps touch use.
- **Diff:** line-numbered monospace panes with distinct additions/removals, bounded scroll height, compact metadata, and a single-column mobile stack.
- **Navigation:** grouped and compact, visible current route, keyboard focus, persisted collapse preference, drawer on small screens.

## Motion and accessibility

Use 140–180ms state transitions for hover/focus only. No decorative looping animation. Preserve visible `:focus-visible`, semantic button labels, 4.5:1 text contrast, keyboard operation, and `prefers-reduced-motion`. Do not announce frequent background refreshes as live status unless the source and update time are explicit.

## Responsive checks

Validate at 1920×1080, 1440×900, 1366×768, 768×1024, and 390×844. At narrow widths: drawer navigation, two-column KPI grid, one-column chart stack, wrapped filters, scroll-contained tables, full-width forms, and stacked diff panes. Verify there is no horizontal overflow on `html`/`body`.
