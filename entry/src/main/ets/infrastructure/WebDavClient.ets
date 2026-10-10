import http from '@ohos.net.http';
import { util } from '@kit.ArkTS';
import { Connection } from '../domain/Connection';
import { FileEntry } from '../domain/FileEntry';
import { Result } from '../domain/Result';
import { ISecureStore } from './SecureStore';
import { ILocalFileService } from './LocalFileService';
import { BusinessError } from '@ohos.base';
import hilog from '@ohos.hilog';

const CHUNK_SIZE = 4 * 1024 * 1024;

type ProgressCallback = (transferred: number, total: number) => void;

export class FileMeta {
  etag: string = '';
  mtime: number = 0;
}

export interface IWebDavClient {
  testConnection(conn: Connection): Promise<Result<boolean>>;
  resolveAddress(conn: Connection): Promise<Result<boolean>>;
  listDirectory(conn: Connection, relativePath: string): Promise<Result<FileEntry[]>>;
  getETag(conn: Connection, relativePath: string): Promise<Result<string>>;
  getFileMeta(conn: Connection, relativePath: string): Promise<Result<FileMeta>>;
  downloadFile(conn: Connection, relativePath: string, localPath: string, resumeOffset: number, onProgress: ProgressCallback): Promise<Result<boolean>>;
  uploadFile(conn: Connection, localPath: string, relativePath: string, onProgress: ProgressCallback): Promise<Result<boolean>>;
  deleteItem(conn: Connection, relativePath: string): Promise<Result<boolean>>;
  mkdir(conn: Connection, relativePath: string): Promise<Result<boolean>>;
  getRemoteSize(conn: Connection, relativePath: string): Promise<Result<number>>;
}

export class WebDavClient implements IWebDavClient {
  private httpClient: http.HttpRequest;
  private secureStore: ISecureStore;
  private localFileService: ILocalFileService;
  private base64: util.Base64Helper = new util.Base64Helper();

  constructor(secureStore: ISecureStore, localFileService: ILocalFileService) {
    this.httpClient = http.createHttp();
    this.secureStore = secureStore;
    this.localFileService = localFileService;
  }

  private encodeFullPath(path: string): string {
    const segs = path.split('/');
    const encoded = segs.map((s: string) => encodeURIComponent(s));
    return encoded.join('/');
  }

  private joinRemotePath(root: string, relative: string): string {
    let rootPath = root === '' ? '/' : root;
    if (!rootPath.startsWith('/')) {
      rootPath = '/' + rootPath;
    }
    let rel = relative === '' || relative === '/' ? '' : relative;
    if (rel !== '' && !rel.startsWith('/')) {
      rel = '/' + rel;
    }
    const joined = rootPath.replace(/\/+$/, '') + rel;
    return joined === '' ? '/' : joined;
  }

  private buildUrl(conn: Connection, relativePath: string): string {
    const base = (conn.activeUrl !== '' ? conn.activeUrl : conn.baseUrl).replace(/\/+$/, '');
    const fullPath = this.joinRemotePath(conn.rootPath, relativePath);
    return base + this.encodeFullPath(fullPath);
  }

  async resolveAddress(conn: Connection): Promise<Result<boolean>> {
    if (conn.activeUrl !== '') {
      return Result.ok(true);
    }
    if (conn.lanUrl !== '') {
      const lanOk = await this.probeUrl(conn, conn.lanUrl);
      if (lanOk) {
        conn.activeUrl = conn.lanUrl;
        return Result.ok(true);
      }
    }
    conn.activeUrl = conn.wanUrl !== '' ? conn.wanUrl : conn.baseUrl;
    return Result.ok(true);
  }

  private async probeUrl(conn: Connection, url: string): Promise<boolean> {
    try {
      const auth = await this.getAuth(conn);
      const probePath = url.replace(/\/+$/, '') + this.encodeFullPath(this.joinRemotePath(conn.rootPath, '/'));
      const resp = await this.httpClient.request(probePath, {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Authorization': auth,
          'Depth': '0',
          'Content-Type': 'application/xml'
        },
        extraData: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/></d:prop></d:propfind>',
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 5000,
        connectTimeout: 5000
      });
      return resp.responseCode > 0;
    } catch (e) {
      return false;
    }
  }

  private async getAuth(conn: Connection): Promise<string> {
    const res = await this.secureStore.loadCredential(conn.credentialRef);
    if (!res.success || res.data === null) {
      return '';
    }
    const token = conn.username + ':' + res.data;
    const encoded = this.base64.encodeToStringSync(new util.TextEncoder().encodeInto(token));
    return 'Basic ' + encoded;
  }

  private info<T>(msg: string): Result<T> {
    return Result.fail(0, msg);
  }

  private basename(path: string): string {
    const trimmed = path.replace(/\/+$/, '');
    const idx = trimmed.lastIndexOf('/');
    return idx >= 0 ? trimmed.substring(idx + 1) : trimmed;
  }

  private safeDecode(s: string): string {
    try {
      return decodeURIComponent(s);
    } catch (e) {
      return s;
    }
  }

  async testConnection(conn: Connection): Promise<Result<boolean>> {
    try {
      await this.resolveAddress(conn);
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, '/');
      const resp = await this.httpClient.request(url, {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Authorization': auth,
          'Depth': '0',
          'Content-Type': 'application/xml'
        },
        extraData: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/></d:prop></d:propfind>',
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 30000,
        connectTimeout: 30000
      });
      const code = resp.responseCode;
      if (code === 401 || code === 403) {
        return Result.fail(code, '认证失败，请检查账号/密码');
      }
      return Result.ok((code >= 200 && code < 300) || code === 207);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, '请求异常：' + err.message);
    }
  }

  async listDirectory(conn: Connection, relativePath: string): Promise<Result<FileEntry[]>> {
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const resp = await this.httpClient.request(url, {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Authorization': auth,
          'Depth': '1',
          'Content-Type': 'application/xml'
        },
        extraData: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getetag/><d:getlastmodified/></d:prop></d:propfind>',
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 60000,
        connectTimeout: 30000
      });
      if (resp.responseCode !== 207 && !(resp.responseCode >= 200 && resp.responseCode < 300)) {
        return Result.fail(resp.responseCode, '列目录失败');
      }
      const xml = resp.result as string;
      const selfPath = this.joinRemotePath(conn.rootPath, relativePath);
      return Result.ok(this.parseListXml(xml, selfPath));
    } catch (e) {
      return Result.fail(-1, '列目录异常');
    }
  }

  private extractTag(block: string, tag: string): string {
    const re = new RegExp('<[^>]*' + tag + '[^>]*>([\\s\\S]*?)<\\/[^>]*' + tag + '>', 'i');
    const m = re.exec(block);
    return m ? m[1].trim() : '';
  }

  private decodeXmlEntities(s: string): string {
    return s
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'");
  }

  private parseHttpDate(str: string): number {
    const s = str.trim();
    let m = /(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/.exec(s);
    if (m !== null) {
      return Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6])) / 1000;
    }
    m = /(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})/.exec(s);
    if (m !== null) {
      const months: string[] = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
      const month = months.indexOf(m[2].toLowerCase());
      if (month >= 0) {
        return Date.UTC(Number(m[3]), month, Number(m[1]), Number(m[4]), Number(m[5]), Number(m[6])) / 1000;
      }
    }
    const parsed = Date.parse(s);
    if (!Number.isNaN(parsed)) {
      return parsed / 1000;
    }
    return 0;
  }

  private parseListXml(xml: string, selfPath: string): FileEntry[] {
    const entries: FileEntry[] = [];
    const selfDecoded = this.safeDecode(selfPath).replace(/\/+$/, '');
    const blocks = xml.split(/<\/[^>]*response[^>]*>/i);
    for (const part of blocks) {
      const startIdx = part.search(/<[^>]*response[^>]*>/i);
      if (startIdx < 0) {
        continue;
      }
      const tagEnd = part.indexOf('>', startIdx);
      if (tagEnd < 0) {
        continue;
      }
      const block = part.substring(tagEnd + 1);
      const href = this.decodeXmlEntities(this.extractTag(block, 'href'));
      const hrefDecoded = this.safeDecode(href).replace(/\/+$/, '');
      if (hrefDecoded === selfDecoded) {
        continue;
      }
      const isCollection = /collection/i.test(block);
      const displayName = this.decodeXmlEntities(this.extractTag(block, 'displayname'));
      const lengthStr = this.extractTag(block, 'getcontentlength');
      const mtimeStr = this.extractTag(block, 'getlastmodified');
      const etag = this.extractTag(block, 'getetag');
      const name = displayName !== '' ? displayName : this.basename(this.safeDecode(href));
      const size = lengthStr !== '' ? Number(lengthStr) : 0;
      const mtime = mtimeStr !== '' ? this.parseHttpDate(mtimeStr) : 0;
      if (entries.length < 3) {
        hilog.info(0x0000, 'WebDAVSync', 'getlastmodified raw=[%{public}s] parsed=%{public}d', mtimeStr, Math.floor(mtime));
      }
      entries.push(new FileEntry(name, isCollection, size, mtime, etag));
    }
    return entries;
  }

  async getETag(conn: Connection, relativePath: string): Promise<Result<string>> {
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const resp = await this.httpClient.request(url, {
        method: http.RequestMethod.HEAD,
        header: { 'Authorization': auth },
        readTimeout: 30000,
        connectTimeout: 30000
      });
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        const h = resp.header as Record<string, string>;
        return Result.ok(h['etag'] ?? h['ETag'] ?? '');
      }
      return Result.fail(resp.responseCode, '获取 ETag 失败');
    } catch (e) {
      return Result.fail(-1, '获取 ETag 异常');
    }
  }

  async getFileMeta(conn: Connection, relativePath: string): Promise<Result<FileMeta>> {
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const resp = await this.httpClient.request(url, {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Authorization': auth,
          'Depth': '0',
          'Content-Type': 'application/xml'
        },
        extraData: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:getlastmodified/><d:getcontentlength/></d:prop></d:propfind>',
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 30000,
        connectTimeout: 30000
      });
      if (resp.responseCode === 207 || (resp.responseCode >= 200 && resp.responseCode < 300)) {
        const xml = resp.result as string;
        const meta = new FileMeta();
        meta.etag = this.extractTag(xml, 'getetag');
        const lastMod = this.extractTag(xml, 'getlastmodified');
        meta.mtime = lastMod !== '' ? this.parseHttpDate(lastMod) : 0;
        return Result.ok(meta);
      }
      return Result.fail(resp.responseCode, '获取文件元信息失败');
    } catch (e) {
      return Result.fail(-1, '获取文件元信息异常');
    }
  }

  async getRemoteSize(conn: Connection, relativePath: string): Promise<Result<number>> {
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const resp = await this.httpClient.request(url, {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Authorization': auth,
          'Depth': '0',
          'Content-Type': 'application/xml'
        },
        extraData: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getcontentlength/></d:prop></d:propfind>',
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 30000,
        connectTimeout: 30000
      });
      if (resp.responseCode === 207 || (resp.responseCode >= 200 && resp.responseCode < 300)) {
        const xml = resp.result as string;
        const lenStr = this.extractTag(xml, 'getcontentlength');
        return Result.ok(lenStr !== '' ? Number(lenStr) : 0);
      }
      return Result.fail(resp.responseCode, '获取文件大小失败');
    } catch (e) {
      return Result.fail(-1, '获取文件大小异常');
    }
  }

  async downloadFile(conn: Connection, relativePath: string, localPath: string, resumeOffset: number, onProgress: ProgressCallback): Promise<Result<boolean>> {
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const sizeRes = await this.getRemoteSize(conn, relativePath);
      if (!sizeRes.success || sizeRes.data === null) {
        return Result.fail(-1, '无法获取远端文件大小');
      }
      const total = sizeRes.data;
      if (total === 0) {
        const emptyRes = await this.localFileService.writeFile(localPath, new Uint8Array(0));
        if (!emptyRes.success) {
          return Result.fail(-1, '写入空文件失败');
        }
        onProgress(0, 0);
        return Result.ok(true);
      }
      let offset = resumeOffset;
      const partPath = localPath + '.part';
      const lastSlash = localPath.lastIndexOf('/');
      if (lastSlash > 0) {
        await this.localFileService.ensureDir(localPath.substring(0, lastSlash));
      }
      while (offset < total) {
        const end = Math.min(offset + CHUNK_SIZE - 1, total - 1);
        const resp = await this.httpClient.request(url, {
          method: http.RequestMethod.GET,
          header: {
            'Authorization': auth,
            'Range': 'bytes=' + offset + '-' + end
          },
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          readTimeout: 120000,
          connectTimeout: 30000
        });
        if (resp.responseCode !== 206 && resp.responseCode !== 200) {
          return Result.fail(resp.responseCode, '下载失败');
        }
        const data = new Uint8Array(resp.result as ArrayBuffer);
        let writeRes: Result<boolean>;
        if (offset === 0) {
          writeRes = await this.localFileService.writeFile(partPath, data);
        } else {
          writeRes = await this.localFileService.appendFile(partPath, data);
        }
        if (!writeRes.success) {
          return Result.fail(-1, '写入本地文件失败：' + writeRes.errorMessage);
        }
        offset += data.length;
        onProgress(offset, total);
      }
      const finalRes = await this.localFileService.atomicReplace(partPath, localPath);
      if (!finalRes.success) {
        return Result.fail(-1, '文件落盘失败');
      }
      return Result.ok(true);
    } catch (e) {
      return Result.fail(-1, '下载异常');
    }
  }

  async uploadFile(conn: Connection, localPath: string, relativePath: string, onProgress: ProgressCallback): Promise<Result<boolean>> {
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const statRes = await this.localFileService.stat(localPath);
      if (!statRes.success || statRes.data === null) {
        return Result.fail(-1, '本地文件不存在');
      }
      const total = statRes.data.size;
      const full = await this.localFileService.readFileRange(localPath, 0, total);
      if (!full.success || full.data === null) {
        return Result.fail(-1, '读取本地文件失败');
      }
      const resp = await this.httpClient.request(url, {
        method: http.RequestMethod.PUT,
        header: {
          'Authorization': auth,
          'Content-Type': 'application/octet-stream',
          'X-OC-Mtime': Math.floor(statRes.data.mtime).toString()
        },
        extraData: full.data.buffer as ArrayBuffer,
        readTimeout: 120000,
        connectTimeout: 30000
      });
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        onProgress(total, total);
        return Result.ok(true);
      }
      return Result.fail(resp.responseCode, '上传失败');
    } catch (e) {
      return Result.fail(-1, '上传异常');
    }
  }

  async deleteItem(conn: Connection, relativePath: string): Promise<Result<boolean>> {
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const resp = await this.httpClient.request(url, {
        method: http.RequestMethod.DELETE,
        header: { 'Authorization': auth },
        readTimeout: 30000,
        connectTimeout: 30000
      });
      return Result.ok(resp.responseCode >= 200 && resp.responseCode < 300);
    } catch (e) {
      return Result.fail(-1, '删除失败');
    }
  }

  async mkdir(conn: Connection, relativePath: string): Promise<Result<boolean>> {
    try {
      const auth = await this.getAuth(conn);
      const url = this.buildUrl(conn, relativePath);
      const resp = await this.httpClient.request(url, {
        method: 'MKCOL' as http.RequestMethod,
        header: { 'Authorization': auth },
        readTimeout: 30000,
        connectTimeout: 30000
      });
      return Result.ok(resp.responseCode >= 200 && resp.responseCode < 300);
    } catch (e) {
      return Result.fail(-1, '创建目录失败');
    }
  }
}