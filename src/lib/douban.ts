// 进程内共享缓存：同一个豆瓣地址在有效期内直接复用结果，所有用户共用；
// 同时进行的相同请求只发一次。以前每个访客打开首页都会重新请求豆瓣，
// 豆瓣偶尔变慢（最长等到 10 秒超时）时整个首页都跟着卡住。
const DOUBAN_CACHE_TTL_MS = 2 * 60 * 60 * 1000; // 2 小时
const DOUBAN_CACHE_MAX_ENTRIES = 300;
const doubanCache = new Map<string, { expiresAt: number; data: unknown }>();
const doubanInflight = new Map<string, Promise<unknown>>();

// 空列表多半是上游临时异常（限流等），不缓存，下次再试
function isCacheableDoubanData(data: unknown): boolean {
  if (!data || typeof data !== 'object') return false;
  const record = data as Record<string, unknown>;
  for (const field of ['items', 'subjects']) {
    if (field in record) {
      const value = record[field];
      return Array.isArray(value) && value.length > 0;
    }
  }
  return true;
}

function rememberDoubanData(url: string, data: unknown) {
  doubanCache.delete(url);
  doubanCache.set(url, { expiresAt: Date.now() + DOUBAN_CACHE_TTL_MS, data });
  // 超过上限时淘汰最早写入的条目（Map 按插入顺序遍历）
  while (doubanCache.size > DOUBAN_CACHE_MAX_ENTRIES) {
    const oldest = doubanCache.keys().next().value;
    if (oldest === undefined) break;
    doubanCache.delete(oldest);
  }
}

/** 仅供测试使用：清空进程内缓存 */
export function clearDoubanDataCache() {
  doubanCache.clear();
  doubanInflight.clear();
}

/**
 * 通用的豆瓣数据获取函数（带进程内缓存）
 * @param url 请求的URL
 * @returns Promise<T> 返回指定类型的数据
 */
export async function fetchDoubanData<T>(url: string): Promise<T> {
  const cached = doubanCache.get(url);
  if (cached && cached.expiresAt > Date.now()) {
    return cached.data as T;
  }

  let pending = doubanInflight.get(url) as Promise<T> | undefined;
  if (!pending) {
    pending = fetchDoubanDataUncached<T>(url)
      .then((data) => {
        if (isCacheableDoubanData(data)) rememberDoubanData(url, data);
        return data;
      })
      .finally(() => {
        doubanInflight.delete(url);
      });
    doubanInflight.set(url, pending);
  }
  return pending;
}

async function fetchDoubanDataUncached<T>(url: string): Promise<T> {
  // 添加超时控制
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 10000); // 10秒超时

  // 设置请求选项，包括信号和头部
  const fetchOptions = {
    signal: controller.signal,
    headers: {
      'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
      Referer: 'https://movie.douban.com/',
      Accept: 'application/json, text/plain, */*',
      Origin: 'https://movie.douban.com',
    },
  };

  try {
    const response = await fetch(url, fetchOptions);
    clearTimeout(timeoutId);

    if (!response.ok) {
      throw new Error(`HTTP error! Status: ${response.status}`);
    }

    return await response.json();
  } catch (error) {
    clearTimeout(timeoutId);
    throw error;
  }
}
