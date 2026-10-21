---
name: Ovid Si
colors:
  surface: '#131317'
  surface-dim: '#131317'
  surface-bright: '#39393d'
  surface-container-lowest: '#0e0e12'
  surface-container-low: '#1b1b1f'
  surface-container: '#1f1f23'
  surface-container-high: '#2a292e'
  surface-container-highest: '#353439'
  on-surface: '#e4e1e7'
  on-surface-variant: '#c9c4d8'
  inverse-surface: '#e4e1e7'
  inverse-on-surface: '#303034'
  outline: '#938ea1'
  outline-variant: '#484555'
  surface-tint: '#cabeff'
  primary: '#cabeff'
  on-primary: '#31009a'
  primary-container: '#947dff'
  on-primary-container: '#2a0088'
  inverse-primary: '#603ce2'
  secondary: '#45dfa4'
  on-secondary: '#003825'
  secondary-container: '#00bd85'
  on-secondary-container: '#00452e'
  tertiary: '#ffb3b0'
  on-tertiary: '#670211'
  tertiary-container: '#ea6767'
  on-tertiary-container: '#5b000d'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#e6deff'
  primary-fixed-dim: '#cabeff'
  on-primary-fixed: '#1c0062'
  on-primary-fixed-variant: '#4816cb'
  secondary-fixed: '#68fcbf'
  secondary-fixed-dim: '#45dfa4'
  on-secondary-fixed: '#002114'
  on-secondary-fixed-variant: '#005137'
  tertiary-fixed: '#ffdad8'
  tertiary-fixed-dim: '#ffb3b0'
  on-tertiary-fixed: '#410006'
  on-tertiary-fixed-variant: '#881d24'
  background: '#131317'
  on-background: '#e4e1e7'
  surface-variant: '#353439'
typography:
  headline-lg:
    fontFamily: Inter
    fontSize: 28px
    fontWeight: '600'
    lineHeight: 39px
    letterSpacing: -0.02em
  headline-sm:
    fontFamily: Inter
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 28px
    letterSpacing: -0.01em
  body-lg:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 22.4px
    letterSpacing: 0em
  body-sm:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 19.6px
    letterSpacing: 0.01em
  caption:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '500'
    lineHeight: 16.8px
    letterSpacing: 0.02em
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  gutter: 1rem
  margin: 1.5rem
  space-xs: 0.25rem
  space-sm: 0.5rem
  space-md: 1rem
  space-lg: 1.5rem
  space-xl: 2rem
---

## Brand & Style

This design system delivers a calm, hyper-refined, tactile dark-mode experience tailored for native Android workflows. Positioned at the intersection of focused engineering and generative creation, the visual tone eliminates distraction in favor of deliberate structural clarity. 

The aesthetic is anchored in deep obsidian tones, disciplined hairline boundaries, and an electric violet accent. It channels modern Material You principles through structural precision: quiet elevation steps, crisp typography, and touch surfaces tuned for mobile performance. Interfaces feel weighted, deliberate, and quiet—allowing user content, generated code, and conversational streams to lead without UI noise.

## Colors

The palette relies on absolute dark values balanced against subtle, desaturated neutral levels and high-visibility intent colors.

- **Background (`#0E0E10`)**: Base canvas underpinning all top-level layouts, ensuring low eye-strain in dark working environments.
- **Surface (`#16161A`)**: Resting elevation tier for cards, input containers, bottom sheets, and app bars.
- **Hairline / Border (`#26262C`)**: Structural definition layer. Used as a 1px boundary across surfaces to replace heavy drop shadows with razor-sharp physical bounds.
- **Primary Accent (`#7C5CFF`)**: Electric Violet. Reserved for primary actions, active indicator highlights, focus states, and model generation cues.
- **Success (`#34D399`)**: Emerald. Applied to execution confirmations, active runtime badges, and passing test assertions.
- **Danger (`#F87171`)**: Rose. Indicates error boundaries, fatal execution states, and destructive controls.
- **Text Layers**:
  - Primary (`#FFFFFF`): Dominant readability tier for user inputs and primary system outputs.
  - Secondary (`#9CA3AF`): Metadata, timestamps, and secondary descriptions.
  - Muted (`#6B7280`): Placeholders, disabled states, and inactive interface markers.

## Typography

The typographic hierarchy utilizes Inter throughout all roles to preserve native mobile legibility and strict visual economy. Every scale operates with a baseline line-height multiplier of 1.4 for clean vertical rhythm.

- **Headline Large (`28px` / Semibold)**: Used for primary view titles and agent workspace headers.
- **Headline Small (`20px` / Semibold)**: Section dividing headers, modal titles, and code block headers.
- **Body Large (`16px` / Regular)**: Main interactive conversational text, AI responses, and code editor body content.
- **Body Small (`14px` / Regular)**: Secondary conversational metadata, ancillary settings labels, and system status lines.
- **Caption (`12px` / Medium)**: Monospaced tags, timestamps, token counters, and micro action labels.

## Layout & Spacing

Layout geometry follows an 8dp grid system with a dedicated 4dp baseline step for micro-elements. 

- **Outer Margin**: Locked to `24px` (`1.5rem`) on mobile interfaces to maintain visual breathing room away from display bevels and camera cutouts.
- **Gutters**: Set to `16px` (`1rem`) across multi-column tablet viewports or split agent panels.
- **Touch Targets**: All interactive targets enforce a strict minimum bound of `48px × 48px`, even when visual boundaries appear smaller.
- **Component Padding Scale**:
  - `space-xs` (4px): Micro-gaps between badge icons and text labels.
  - `space-sm` (8px): Inner pill button padding and compact list element spacing.
  - `space-md` (16px): Standard inner card padding and input field internal gutters.
  - `space-lg` (24px): Inter-section separation and full sheet padding.
  - `space-xl` (32px): Structural spacing before bottom action bars and chat dock anchors.

## Elevation & Depth

Visual hierarchy avoids heavy, noisy drop shadows in favor of a surface-tier system bound by hairline borders.

- **Level 0 (Canvas)**: Background color (`#0E0E10`). Zero elevation. Houses the primary scroll viewport.
- **Level 1 (Card & Section Container)**: Surface color (`#16161A`) framed with a 1px solid hairline border (`#26262C`). No drop shadow is applied; separation is driven by fill delta and the subtle boundary outline.
- **Level 2 (Active Floating Dock & Toolbars)**: Surface tint (`#16161A`) elevated with a low-opacity ambient drop shadow: `0 8px 24px rgba(0, 0, 0, 0.45)` accompanied by the 1px hairline border (`#26262C`).
- **Level 3 (Modals & Bottom Sheets)**: Surface `#1B1B22` framed by `#26262C` borders, using a `0 16px 32px rgba(0, 0, 0, 0.6)` ambient shadow with an underlying scrim (`#000000` at 65% opacity).
- **Glow Accentuation**: Primary interactive focal points (such as active agent listening or code generation) may invoke a subtle diffuse violet illumination: `0 0 16px rgba(124, 92, 255, 0.18)`.

## Shapes

The design system uses deliberate curvature steps to communicate containment and interactability:

- **Cards & Primary Modules**: `16px` (`rounded-lg` / `1rem`) corner radius. Encapsulates code snippets, conversational cards, and modal sheets.
- **Inputs & Interactive Containers**: `12px` corner radius. Applied to text fields, search docks, toolbars, and contextual chips.
- **Pills & Status Identifiers**: `9999px` (Full Pill). Applied to status tags, prompt execution triggers, quick-replies, and primary call-to-action buttons.

## Components

### Buttons
- **Primary Button**: Full pill radius (`9999px`), background `#7C5CFF`, text `#FFFFFF` (14px, Semibold), minimum height 48px, horizontal padding 20px. Press state dims to 90% opacity with a scale down to `0.98`.
- **Secondary / Surface Button**: Full pill radius, background `#16161A`, border 1px solid `#26262C`, text `#9CA3AF`. Hover/press transitions border to `#7C5CFF` and text to `#FFFFFF`.
- **Destructive Button**: Full pill radius, background `transparent`, border 1px solid `#F87171`, text `#F87171`.

### Chips & Action Tags
- **Selection Chips**: Height 36px, corner radius 12px, border 1px solid `#26262C`, background `#16161A`, text `#9CA3AF`. Active state shifts background to `rgba(124, 92, 255, 0.12)`, border to `#7C5CFF`, and text to `#FFFFFF`.
- **Status Badges**: Full pill radius, height 24px, padding 4px 10px, typography 12px caption. Emerald indicator dot for successful builds, rose for failed executions.

### Cards & Code Blocks
- **Card**: Background `#16161A`, border 1px solid `#26262C`, radius 16px, inner padding 16px.
- **Code Block Container**: Embedded within a 16px radius card, header row divided by a 1px bottom border `#26262C`, dark background `#0E0E10`, monospaced typography with 1.4 line-height and integrated copy triggers.

### Input Fields
- **Prompt & Text Fields**: Minimum height 48px, corner radius 12px, background `#16161A`, border 1px solid `#26262C`, text `#FFFFFF`, placeholder `#6B7280`. Focused state elevates border to `#7C5CFF` and applies a subtle 1px inner ring.

### Lists & Chat Stream
- **Chat Bubbles (Agent)**: Background `#16161A`, border 1px solid `#26262C`, radius 16px, padding 16px.
- **Chat Bubbles (User)**: Background `#26262C`, radius 16px, padding 16px, text `#FFFFFF`, aligned right with 24px margin buffer.
- **List Items**: Minimum height 56px for tactile touch selection, divided by 1px solid `#26262C` hairlines, with primary text in `#FFFFFF` and supporting labels in `#9CA3AF`.