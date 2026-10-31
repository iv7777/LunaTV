'use client';

export interface BangumiCalendarData {
  weekday: {
    en: string;
  };
  items: {
    id: number;
    name: string;
    name_cn: string;
    rating: {
      score: number;
    };
    air_date: string;
    images: {
      large: string;
      common: string;
      medium: string;
      small: string;
      grid: string;
    };
  }[];
}

export async function GetBangumiCalendarData(): Promise<BangumiCalendarData[]> {
  const response = await fetch('/api/bangumi/calendar');
  if (!response.ok) {
    throw new Error(`获取番剧日历失败: HTTP ${response.status}`);
  }
  const data = await response.json();
  const filteredData = data.map((item: BangumiCalendarData) => ({
    ...item,
    items: item.items.filter(bangumiItem => bangumiItem.images)
  }));

  return filteredData;
}

type BangumiImages = {
  large?: string;
  common?: string;
  medium?: string;
  small?: string;
  grid?: string;
};

/**
 * 卡片用的 Bangumi 封面：large 是原图（常见 500 KB～2 MB），common 只有 150×211 太糊。
 * Bangumi 图床支持 /r/<宽度>/ 缩放，这里取指定宽度的缩略图（400 宽约 70 KB），并统一用 https。
 */
export function getBangumiCoverUrl(images?: BangumiImages | null, width = 400): string {
  const large = images?.large;
  if (large && /^https?:\/\/lain\.bgm\.tv\/pic\//.test(large)) {
    return large.replace(/^https?:\/\/lain\.bgm\.tv\/pic\//, `https://lain.bgm.tv/r/${width}/pic/`);
  }
  return large || images?.common || images?.medium || images?.small || images?.grid || '';
}
