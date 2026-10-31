import { act, render, screen } from '@testing-library/react';

import LazySection from '@/components/LazySection';

describe('LazySection', () => {
  afterEach(() => {
    delete (window as unknown as { IntersectionObserver?: unknown })
      .IntersectionObserver;
  });

  test('浏览器不支持 IntersectionObserver 时直接渲染内容', () => {
    render(
      <LazySection>
        <p>内容</p>
      </LazySection>
    );
    expect(screen.getByText('内容')).toBeInTheDocument();
  });

  test('滚动到附近之前只渲染占位，进入视口后渲染内容', () => {
    let trigger: (entries: Array<{ isIntersecting: boolean }>) => void = () =>
      undefined;
    (
      window as unknown as { IntersectionObserver: unknown }
    ).IntersectionObserver = class {
      constructor(cb: typeof trigger) {
        trigger = cb;
      }
      observe() {
        return undefined;
      }
      disconnect() {
        return undefined;
      }
    };

    render(
      <LazySection>
        <p>内容</p>
      </LazySection>
    );
    expect(screen.queryByText('内容')).not.toBeInTheDocument();
    act(() => trigger([{ isIntersecting: true }]));
    expect(screen.getByText('内容')).toBeInTheDocument();
  });
});
