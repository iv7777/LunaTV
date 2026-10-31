'use client';

import { ReactNode, useEffect, useRef, useState } from 'react';

interface LazySectionProps {
  children: ReactNode;
  /** 占位高度（未渲染前撑住页面，避免滚动条跳动） */
  placeholderClassName?: string;
  /** 提前多少距离开始渲染，默认在进入视口前 600px 就渲染 */
  rootMargin?: string;
}

/**
 * 首屏以下的模块在滚动到附近时才挂载。
 * 首页一次渲染所有行会产生近 3000 个 DOM 节点、几十张图片，手机上主线程被占满，
 * 点击会明显卡顿；延迟挂载后首屏只渲染看得到的内容。
 * 一旦显示就不再卸载，来回滚动不会重复加载。
 */
export default function LazySection({
  children,
  placeholderClassName = 'mb-8 min-h-[240px] sm:min-h-[340px]',
  rootMargin = '600px 0px',
}: LazySectionProps) {
  const ref = useRef<HTMLDivElement>(null);
  // 不支持 IntersectionObserver 的老浏览器直接渲染
  const [visible, setVisible] = useState(
    () =>
      typeof window !== 'undefined' &&
      typeof IntersectionObserver === 'undefined'
  );

  useEffect(() => {
    if (visible) return;
    const el = ref.current;
    if (!el) return;
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          setVisible(true);
          observer.disconnect();
        }
      },
      { rootMargin }
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, [visible, rootMargin]);

  if (visible) return <>{children}</>;
  return <div ref={ref} className={placeholderClassName} aria-hidden='true' />;
}
