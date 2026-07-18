# Calee colour tokens

This document defines the initial shared colour contract for Calee products.
The goal is one recognisable brand across family, school, community, and
business experiences, while allowing controlled differences in background and
surface treatment.

## Core brand

| Token | Value | Purpose |
| --- | --- | --- |
| `brand.primary` | `#1F6F66` | Primary actions, selected navigation, focus |
| `brand.primaryDark` | `#195B55` | Pressed and high-emphasis states |
| `brand.primaryDeep` | `#163F3B` | High-contrast brand text and icons |
| `brand.primaryLight` | `#4F9188` | Supporting brand accents |
| `brand.primarySoft` | `#DDEFEA` | Selected rows, chips, containers |
| `brand.secondary` | `#A35F2A` | Warm family and premium accent |
| `brand.secondarySoft` | `#F4E4D5` | Warm supporting containers |

## Neutral surfaces

| Token | Value | Purpose |
| --- | --- | --- |
| `background.default` | `#F3F7F6` | Mobile and business-neutral background |
| `surface.default` | `#FFFFFF` | Cards, forms, sheets, dialogs |
| `surface.subtle` | `#F0F7F5` | Low-emphasis panels |
| `text.primary` | `#163330` | Main content |
| `text.secondary` | `#4F625F` | Supporting content |
| `text.tertiary` | `#7D8E8A` | Hints and low-emphasis metadata |
| `border.default` | `#D5E1DE` | Dividers and field borders |
| `border.strong` | `#B7C8C4` | Outlined controls and stronger separation |

## Semantic colours

Semantic colours must not be replaced by the brand colour.

| Token | Value | Purpose |
| --- | --- | --- |
| `status.success` | `#2E7D5A` | Successful completion |
| `status.warning` | `#A86300` | Warnings and attention |
| `status.information` | `#2F80ED` | Informational links and notices |
| `status.destructive` | `#C23B32` | Errors and destructive actions |

## Product variants

Calee products share the same brand and semantic colours. Variants may change
only approved environmental tokens.

- **Calee Family:** may use warmer backgrounds and the secondary bronze accent
  for onboarding, meals, chores, and lifestyle content.
- **Calee Business:** uses neutral or cool surfaces and restrained use of the
  secondary accent.
- **CaleeMobile:** uses the neutral surface set so the app remains familiar on
  iOS and Android while retaining the Calee identity.

## Calendar colours

Calendar and event colours are functional data colours. They must remain a
separate palette and must not be derived from `brand.primary`. A calendar event
using teal must not acquire selected, system-owned, or privileged meaning.

## Implementation rules

1. Components consume semantic tokens rather than raw hex values.
2. New raw brand hex values are added only in a central theme or generated token
   file.
3. Every interactive colour includes default, pressed, focused, selected, and
   disabled behaviour.
4. Text and controls must meet the applicable WCAG contrast requirement.
5. Theme changes are released per product through small, reversible pull
   requests rather than a cross-repository search-and-replace.
