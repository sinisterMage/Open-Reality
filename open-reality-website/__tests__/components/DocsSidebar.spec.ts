import { describe, it, expect, beforeEach } from 'bun:test'
import { mount } from '@vue/test-utils'
import DocsSidebar from '~/components/DocsSidebar.vue'
import { defaultMountOptions } from '../helpers'

describe('DocsSidebar', () => {
  beforeEach(() => {
    ;(globalThis as any).useRoute = () => ({ path: '/docs' })
  })

  it('renders all 11 documentation sections', () => {
    const wrapper = mount(DocsSidebar, defaultMountOptions)
    const links = wrapper.findAll('a')
    expect(links).toHaveLength(11)
  })

  it('renders section labels', () => {
    const wrapper = mount(DocsSidebar, defaultMountOptions)
    expect(wrapper.text()).toContain('Getting Started')
    expect(wrapper.text()).toContain('Architecture')
    expect(wrapper.text()).toContain('Rendering')
    expect(wrapper.text()).toContain('Audio')
  })

  it('highlights active route /docs', () => {
    const wrapper = mount(DocsSidebar, defaultMountOptions)
    const activeLink = wrapper.find('.border-or-green')
    expect(activeLink.exists()).toBe(true)
    expect(activeLink.text()).toBe('Getting Started')
  })

  it('highlights a different route', () => {
    ;(globalThis as any).useRoute = () => ({ path: '/docs/physics' })
    const wrapper = mount(DocsSidebar, defaultMountOptions)
    const activeLink = wrapper.find('.border-or-green')
    expect(activeLink.exists()).toBe(true)
    expect(activeLink.text()).toBe('Physics')
  })

  it('renders the Documentation heading', () => {
    const wrapper = mount(DocsSidebar, defaultMountOptions)
    expect(wrapper.find('h3').text()).toBe('Documentation')
  })
})
