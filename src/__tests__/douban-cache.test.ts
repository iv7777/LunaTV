/** @jest-environment node */
import { clearDoubanDataCache, fetchDoubanData } from '@/lib/douban';

function jsonResponse(body: unknown, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  } as Response;
}

const fetchMock = jest.fn();

beforeEach(() => {
  clearDoubanDataCache();
  fetchMock.mockReset();
  (global as unknown as { fetch: typeof fetchMock }).fetch = fetchMock;
});

describe('fetchDoubanData 进程内缓存', () => {
  test('同一个地址第二次直接返回缓存，不再请求豆瓣', async () => {
    fetchMock.mockResolvedValue(jsonResponse({ items: [{ id: '1' }] }));
    const a = await fetchDoubanData('https://m.douban.com/a');
    const b = await fetchDoubanData('https://m.douban.com/a');
    expect(a).toEqual({ items: [{ id: '1' }] });
    expect(b).toEqual(a);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test('同时进行的相同请求只发一次', async () => {
    let release: (value: Response) => void = () => undefined;
    fetchMock.mockReturnValue(new Promise<Response>((r) => (release = r)));
    const pending = Promise.all([
      fetchDoubanData('https://m.douban.com/b'),
      fetchDoubanData('https://m.douban.com/b'),
    ]);
    release(jsonResponse({ subjects: [{ id: '2' }] }));
    const [a, b] = await pending;
    expect(a).toEqual(b);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test('空列表和失败的请求不缓存，下次重新请求', async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ items: [] }));
    await fetchDoubanData('https://m.douban.com/c');
    fetchMock.mockResolvedValueOnce(jsonResponse({}, 503));
    await expect(fetchDoubanData('https://m.douban.com/c')).rejects.toThrow(
      '503'
    );
    fetchMock.mockResolvedValueOnce(jsonResponse({ items: [{ id: '3' }] }));
    expect(await fetchDoubanData('https://m.douban.com/c')).toEqual({
      items: [{ id: '3' }],
    });
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });
});
