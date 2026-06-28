---
name: sorbet-inline-rbs
description: Create RBS type signatures using Sorbet's inline RBS comment syntax.
---

# Sorbet Inline RBS Signatures

This project uses Sorbet with RBS comment syntax (`--enable-experimental-rbs-comments`). We do NOT use sorbet-runtime (no `T.let`, `T.nilable`, `sig {}` blocks, etc.).

## Documentation Reference
- https://sorbet.org/docs/rbs-support

## Key Rules

### 1. Use `#:` for type annotations
```ruby
#: (Integer) -> String
def foo(x); end
```

### 2. Use concise syntax - no empty parens
```ruby
# Good
#: -> String
def foo; end

# Bad - don't use empty parens
#: () -> String
def foo; end
```
(One exception: a block self-binding keeps the `()` — `{ () [self: T] -> void }` — to
match the Sorbet docs form. The bare `{ [self: T] -> void }` also parses if you prefer it.)

### 3. Multi-line signatures use `#|` continuation
```ruby
#: (step: MessageFlow::Step, status: Symbol, completed: bool,
#|  recipient_count: Integer) -> ActiveSupport::SafeBuffer
def render_step(step:, status:, completed:, recipient_count:)
```

### 4. Instance variables - annotate on same line
```ruby
@steps ||= STEPS.map { |attrs| Step.new(**attrs) } #: Array[Step]?
@current_step ||= steps.find { |s| !completed?(s) } || steps.last #: Step?
```

### 5. Constants - annotate at end of line
```ruby
STEPS = [...].freeze #: Array[Hash[Symbol, untyped]]
```

### 6. Attribute readers - group by type
```ruby
#: Symbol
attr_reader :key, :icon
#: String
attr_reader :name, :description, :template
#: ActiveSupport::Duration?
attr_reader :send_before_event, :send_after_event
```

### 7. `typed: true` is the default; `typed: strict` is reachable
- `typed: true` is the practical default for most files
- `typed: strict` requires a signature for EVERY method and a declaration for every ivar.
  Many files CAN reach strict using the patterns below (named block params, `#: as !nil`
  readers for before_action ivars, `# @abstract`/`#: self as` annotations) — prefer strict
  when it's clean.
- The usual blocker is **`Data.define` accessors**: they have no sigs in strict mode, so a
  class using `Data.define` generally stays `typed: true`.

### 8. RBS shim files go next to the .rb file
If needed, place `.rbs` files in the same directory as the `.rb` file, not in `sorbet/rbi/shims/`.

### 9. `UI.*` facade methods get NO sigs
The one-line factory methods in `app/components/ui/**/methods.rb` just forward
`**args` / `&block` to a component constructor. Leave these files **unsigiled**
with **no `#:` sigs** — every param is `untyped` so the signature is pure noise,
and typing the forwarded block (`?{ ... }`) breaks tapioca (it can't translate an
anonymous `&`; see gotcha 6). Keep them plain:
```ruby
# app/components/ui/data_display/methods.rb  (no `# typed:` sigil, no `#:` lines)
module UI::DataDisplay::Methods
  def gallery(**args, &) = UI::DataDisplay::GalleryComponent.new(**args, &)
  def photo_modal(**args, &) = UI::DataDisplay::Gallery::PhotoModalComponent.new(**args, &)
end
```

## Type Syntax Quick Reference

| RBS Syntax | Meaning |
|------------|---------|
| `Type?` | Nilable (T.nilable) |
| `Type1 \| Type2` | Union (T.any) |
| `Type1 & Type2` | Intersection (T.all) |
| `[Type1, Type2]` | Tuple |
| `{ key: Type }` | Shape/Hash (note the `key:` — this is a hash, not a block) |
| `^(Type) -> Type` | Proc/Lambda passed as a **value** (e.g. a proc argument) |
| `{ (Type) -> Ret }` | A method's **block** (required) — sits before the `->` return |
| `?{ (Type) -> Ret }` | A method's block (optional) |
| `{ () [self: T] -> Ret }` | A block run with `self` rebound (instance_eval/instance_exec) |
| `Array[Type]` | Generic array |
| `Hash[K, V]` | Generic hash |
| `untyped` | Escape hatch |
| `expr #: as Type` | Cast/assert an expression to `Type` (static only) |
| `expr #: as !nil` | Assert non-nil — drops nil from the type |
| `#: self as Type` | Re-bind `self` for the enclosing block/lambda body |

## Common Patterns

### Method with keyword args
```ruby
#: (message_flow: MessageFlow, ?current_step_key: Symbol?, ?clickable: bool) -> void
def initialize(message_flow:, current_step_key: nil, clickable: true)
```

### Method accepting multiple types
```ruby
#: (Step | Symbol) -> bool
def step_completed?(step)
```

### Optional parameter with nil default
```ruby
#: (?(Symbol | String | nil)) -> Step
def resolve_step(key = nil)
```

### ActiveRecord relations
```ruby
#: (Step | Symbol) -> Participant::PrivateRelation
def participants_for_step(step)
```

### Type assertions / casts — `#: as`
Narrow or coerce an expression with a trailing `#: as Type`. The most common form is
`#: as !nil` for "I know this is present":
```ruby
step = find_step(step) #: as !nil                                  # Step? -> Step
rgb  = pairs.map { |p| p.to_i(16) } #: as [Integer, Integer, Integer]  # Array -> tuple
```
`#: as !nil` is the idiom for dropping nil (used all over `message_flow.rb`). Static
assertion only — no runtime check (we don't use sorbet-runtime, so no `T.must`/`T.cast`).

### Non-nil ivars set in a before_action / callback
You **cannot** assign a non-nil value to an ivar outside `initialize` — Sorbet errors
(5005/5013: "declare inside initialize or declare nilable", suggests `T.let`) **even at
`typed: true`**, and this project forbids `T.let`. So keep the ivar **nilable** and expose
a **non-nil reader** that asserts presence (the before_action's guard guarantees it):
```ruby
#: -> void
def set_configuration
  configuration = event.guest_share_configuration
  return render(file: ..., status: :not_found) unless valid?(configuration)
  @configuration = configuration #: GuestShareConfiguration?   # nilable ivar — no 5005
end

#: -> GuestShareConfiguration
def guest_share_configuration
  @configuration #: as !nil                                    # non-nil reader
end
```
Consumers call the reader method, not `@configuration` directly. This is the
`WithEvent#event` pattern (memoized lookups are the same idea: `@event ||= … #: Event?`
behind a `#: -> Event` method). It's also what lets such a file reach `typed: strict`.

### Concerns (modules mixed into a class)
```ruby
# @abstract                                      # module declares an abstract method
# @requires_ancestor: ::ApplicationController
# @requires_ancestor: ::WithEvent
module GuestShareScoped
  extend ActiveSupport::Concern

  included do
    #: self as singleton(ApplicationController)   # the included block is class_eval'd
    before_action :set_configuration
  end

  # @abstract                                     # includer must implement
  #: -> Event
  def event = raise(NotImplementedError)
end
```
- `# @requires_ancestor: ::X` — the module is only mixed into `X`, so Sorbet lets it call
  `X`'s methods (`before_action`, `current_user`, `render`, …).
- `#: self as singleton(X)` inside `included do` — that block runs in `X`'s singleton (class) context.
- `# @abstract` marks the module (when it has an abstract method) **and** each abstract
  method; `# @overridable` marks a method subclasses may override.

### Blocks — type the block AND name the param (never anonymous `&`)
The block type sits **just before the method's return `->`**. A typed block needs a
**named** param (`&block`) — an anonymous `&` cannot be translated to a Sorbet
signature: tapioca fails with `unexpected ':'` (it emits `params(..., : T.proc.void)`).
**`srb tc` misses this in a `typed: false` file; tapioca / RBI generation catches it.**
```ruby
# Forwarded block — type it, name the param, forward by name.
# This one is instance_exec'd, so bind self in the block type (see the
# "self inside instance_exec" section); callers then need no `#: self as`.
#: (?placement: Symbol?) { [self: Filters::Builder] -> void } -> void
def filters(placement: nil, &block)
  Filters::Builder.new(...).instance_exec(&block)
end

# Block used by name (called/stored)
#: (success_component: untyped) ?{ -> void } -> void
def save_and_render(success_component:, &after_save)
  after_save&.call
end
```
RuboCop's `Naming/BlockForwarding` and `Style/ArgumentsForwarding` will otherwise
rewrite a *forwarded* `&block` back to anonymous `&` (re-breaking tapioca), so the
project `.rubocop.yml` disables that conflict:
```yaml
Naming/BlockForwarding:
  Enabled: false
Style/ArgumentsForwarding:
  RedundantBlockArgumentNames: []
```
`{ ... }` types the method's **block**; `^(...) -> ...` types a proc passed as a
**value** (e.g. `(on_click: ^() -> void)`). Different things — don't swap them.

### `self` inside instance_exec / instance_eval / DSL blocks
When a method runs your block with `instance_exec`/`instance_eval`, `self` inside the
block is the *receiver*, not the lexical class. Two fixes — prefer the first.

**You own the method that runs the block →** bind `self` in the method's block type with
`[self: T]`. This is the canonical Sorbet form, and it fixes **every** call site at once —
callers write the DSL with no annotation:
```ruby
#: { () [self: SomeGem::Configuration] -> void } -> void
def self.configure(&block)
  config = SomeGem::Configuration.new
  config.instance_eval(&block)
end

SomeGem.configure { setting :a }   # `setting` resolves on Configuration — no call-site annotation
```
This is the right fix for our adapter DSLs (`actions do … end`, `filters do … end`,
`index do … end`): bind the block to `ResourceAdapter::Index::Builder` in the `#:` sig
once, instead of annotating each `do … end`.

**It's framework code you don't own →** you can't change its block type (Rails
`validates if:` / `with_options`, a lambda you pass into `configure_views`), so annotate
the block body's **first line** with `#: self as Type`:
```ruby
validates :body, if: -> {
  #: self as MassCommunication
  template.requires_body?
}

configure_views(index_component: -> {
  #: self as App::GuestSharesController
  SomeComponent.new(resource:)
})
```

**`instance_exec` caveat:** `[self: T]` fixes the *call site* for both, and the method
*body* type-checks clean for `instance_eval`. But `instance_exec(&block)` itself still
errors 7002 at `typed: true` (Sorbet's `instance_exec` RBI expects a `(*args)` proc, not a
no-arg `Proc0`), so a method using `instance_exec` stays `typed: false` or casts the block.

## Gotchas

1. **Comment must be immediately before def** - blank lines break it
2. **No runtime type checking** - RBS comments are static analysis only
3. **Data.define accessors** - Can't easily type in strict mode, use `typed: true`
4. **Hash splat with keyword params** - Sorbet can't handle `Step.new(**attrs)` well in strict mode
5. **Date arithmetic with Duration** - Sorbet's Date RBI doesn't know about ActiveSupport::Duration extensions
6. **Typed block ⇒ named param** - a typed block (`{ }`/`?{ }`) needs a NAMED param (`&block`); an anonymous `&` breaks tapioca's RBS→RBI translation (`unexpected ':'`), and `srb tc` misses it in `typed: false` files. RuboCop's `Naming/BlockForwarding` / `Style/ArgumentsForwarding` are configured (in `.rubocop.yml`) to allow named block params so they aren't reverted to `&`. (`{ () -> T }` types the *block*; `^() -> T` types a *proc value* — different.)
7. **instance_exec'd blocks/lambdas** - `self` is rebound, so the block body can't see the lexical class's methods. If you own the method, bind it in the block type — `#: { () [self: T] -> void } -> void` — and every call site just works (our adapter `actions`/`filters`/`index` DSLs). If it's framework code you don't own (Rails `validates if:` / `with_options`; a lambda passed to `configure_views`), add `#: self as Type` as the block's first line instead. (`instance_exec` bodies still trip 7002 at `typed: true`; `instance_eval` doesn't.)
8. **Non-nil ivar outside `initialize`** - errors (5005) **even at `typed: true`**; this project can't use `T.let`. Keep the ivar nilable and add a `#: as !nil` reader method (the `WithEvent#event` pattern). This is also what lets the file reach `typed: strict`.
9. **Concern callbacks** - the `included do … end` block runs in the host's singleton context: annotate `#: self as singleton(TheClass)`, and mark the module `# @requires_ancestor: ::TheClass` so it can see the host's instance methods.
10. **Array of hashes — start empty, don't seed with a literal.** Seeding an array with a hash literal makes Sorbet infer a rigid **shape** element (with literal value types), so a later `<<` of a differently-keyed/valued hash fails: `Expected {label: String("Photos"), …} but found {label: String("Voice message"), …}`. Build it empty and push instead:
    ```ruby
    # Bad — element type locks to the first hash's shape
    options = [{label: 'Photos', value: 'photos'}]
    options << {label: 'Audio', value: 'audio'} if audio?   # ← shape mismatch error

    # Good — start empty (untyped element), then push
    options = []
    options << {label: 'Photos', value: 'photos'}
    options << {label: 'Audio', value: 'audio'} if audio?
    ```
    To keep the elements typed instead of untyped, annotate: `options = [] #: Array[Hash[Symbol, String]]`. (This is the table's *shape* `{ key: Type }` vs general `Hash[K, V]` distinction biting at inference time.)
