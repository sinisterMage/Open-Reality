<script setup lang="ts">
const links = [
  { label: 'Features', href: '/#features' },
  { label: 'Examples', href: '/#examples' },
  { label: 'Demo', href: '/demo' },
  { label: 'Docs', href: '/docs' },
]
const mobileOpen = ref(false)
</script>

<template>
  <nav class="sticky top-0 z-50 border-b border-or-border bg-or-bg/80 backdrop-blur-md">
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
      <div class="flex items-center justify-between h-16">
        <NuxtLink to="/" class="flex items-center gap-2">
          <span class="text-or-green font-mono font-bold text-xl">&gt;_</span>
          <span class="font-mono font-bold text-or-text text-lg">OpenReality</span>
        </NuxtLink>

        <div class="hidden md:flex items-center gap-8">
          <NuxtLink
            v-for="link in links"
            :key="link.label"
            :to="link.href"
            class="text-or-text-dim hover:text-or-green transition-colors font-mono text-sm"
          >
            {{ link.label }}
          </NuxtLink>
          <a
            href="https://github.com/sinisterMage/Open-Reality"
            target="_blank"
            class="border border-or-border px-4 py-1.5 rounded text-sm font-mono text-or-text-dim hover:text-or-green hover:border-or-green transition-all"
          >
            GitHub
          </a>
        </div>

        <button class="md:hidden text-or-text-dim" @click="mobileOpen = !mobileOpen">
          <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path v-if="!mobileOpen" stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16" />
            <path v-else stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
          </svg>
        </button>
      </div>

      <div v-if="mobileOpen" class="md:hidden pb-4 space-y-2">
        <NuxtLink
          v-for="link in links"
          :key="link.label"
          :to="link.href"
          class="block text-or-text-dim hover:text-or-green font-mono text-sm py-1"
          @click="mobileOpen = false"
        >
          {{ link.label }}
        </NuxtLink>
        <a
          href="https://github.com/sinisterMage/Open-Reality"
          target="_blank"
          class="block text-or-text-dim hover:text-or-green font-mono text-sm py-1"
        >
          GitHub
        </a>
      </div>
    </div>
  </nav>
</template>
