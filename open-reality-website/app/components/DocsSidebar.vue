<script setup lang="ts">
const route = useRoute()

const sections = [
  { label: 'Getting Started', to: '/docs' },
  { label: 'Architecture', to: '/docs/architecture' },
  { label: 'Components', to: '/docs/components' },
  { label: 'Systems', to: '/docs/systems' },
  { label: 'Physics', to: '/docs/physics' },
  { label: 'Rendering', to: '/docs/rendering' },
  { label: 'Scripting', to: '/docs/scripting' },
  { label: 'Gameplay', to: '/docs/gameplay' },
  { label: 'Terrain', to: '/docs/terrain' },
  { label: 'Audio', to: '/docs/audio' },
]
</script>

<template>
  <aside class="hidden lg:block w-64 shrink-0 border-r border-or-border bg-or-surface">
    <nav class="sticky top-16 p-6 space-y-1">
      <h3 class="font-mono text-xs text-or-text-dim uppercase tracking-wider mb-4">
        Documentation
      </h3>
      <NuxtLink
        v-for="s in sections"
        :key="s.to"
        :to="s.to"
        :class="[
          'block px-3 py-2 rounded text-sm font-mono transition-colors',
          route.path === s.to
            ? 'bg-or-green/10 text-or-green border-l-2 border-or-green'
            : 'text-or-text-dim hover:text-or-text hover:bg-or-panel'
        ]"
      >
        {{ s.label }}
      </NuxtLink>
    </nav>
  </aside>
</template>
