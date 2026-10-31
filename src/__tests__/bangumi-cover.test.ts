import { getBangumiCoverUrl } from '@/lib/bangumi.client';

describe('getBangumiCoverUrl', () => {
  test('Bangumi 原图改为指定宽度的缩略图并使用 https', () => {
    expect(
      getBangumiCoverUrl({
        large: 'http://lain.bgm.tv/pic/cover/l/52/fe/418229_gcFij.jpg',
      })
    ).toBe('https://lain.bgm.tv/r/400/pic/cover/l/52/fe/418229_gcFij.jpg');
  });

  test('其它图床或缺少大图时按原来的顺序回退', () => {
    expect(getBangumiCoverUrl({ large: 'https://example.com/a.jpg' })).toBe(
      'https://example.com/a.jpg'
    );
    expect(getBangumiCoverUrl({ medium: 'm.jpg', small: 's.jpg' })).toBe(
      'm.jpg'
    );
    expect(getBangumiCoverUrl(undefined)).toBe('');
  });
});
