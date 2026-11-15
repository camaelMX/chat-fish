import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

/** 一条对话消息 */
export interface ChatMessage {
  role: string;
  content: string;
}

interface RequestBody {
  model: string;
  messages: ChatMessage[];
  stream: boolean;
  temperature: number;
  thinking?: Thinking;
  reasoning_effort?: string;
}

interface Thinking {
  type: string;
}

interface Delta {
  content?: string;
  reasoning_content?: string;
}

interface Choice {
  delta?: Delta;
}

interface Chunk {
  choices?: Choice[];
  usage?: Usage;
}

interface Usage {
  prompt_tokens?: number;
  completion_tokens?: number;
  prompt_cache_hit_tokens?: number;
  prompt_cache_miss_tokens?: number;
}

interface ErrorDetail {
  message?: string;
}

interface ErrorBody {
  error?: ErrorDetail;
}

interface ModelItem {
  id?: string;
}

interface ModelListResp {
  data?: ModelItem[];
}

interface NonStreamMessage {
  content?: string;
}

interface NonStreamChoice {
  message?: NonStreamMessage;
}

interface NonStreamResp {
  choices?: NonStreamChoice[];
}

/** chatOnce 的请求体（非流式） */
interface OnceFormat {
  type: string;
}

interface OnceBody {
  model: string;
  messages: ChatMessage[];
  stream: boolean;
  temperature: number;
  max_tokens: number;
  thinking: Thinking;
  response_format?: OnceFormat;
}

const OFFICIAL_HOST: string = 'https://api.deepseek.com';

/**
 * DeepSeek 流式聊天服务。
 * 使用 SSE（text/event-stream）逐块解析 delta，边收边回调。
 * 既支持官方接口，也支持三方兼容接口（填 base url 即可）。
 */
export class DeepSeekService {
  private req: http.HttpRequest | undefined = undefined;
  /** 接口主机。官方默认，三方由用户在设置里填 */
  host: string = OFFICIAL_HOST;

  private chatEndpoint(): string {
    return this.host + '/chat/completions';
  }

  private modelsEndpoint(): string {
    return this.host + '/models';
  }

  /**
   * 把用户填的地址收拾成规范的 base url。
   * 允许填 https://api.xxx.com、…/v1、甚至 …/v1/chat/completions。
   */
  static normalizeHost(raw: string): string {
    let s: string = raw.trim();
    if (s.length === 0) {
      return OFFICIAL_HOST;
    }
    if (!/^https?:\/\//i.test(s)) {
      s = 'https://' + s;
    }
    // 去掉末尾斜杠
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    // 用户把完整路径也贴进来时，截到 base
    const cut: number = s.indexOf('/chat/completions');
    if (cut > 0) {
      s = s.substring(0, cut);
    }
    const cutModels: number = s.indexOf('/models');
    if (cutModels > 0) {
      s = s.substring(0, cutModels);
    }
    return s;
  }

  async chatStream(apiKey: string, model: string, messages: ChatMessage[], effort: string,
    onDelta: (text: string) => void,
    onUsage: (inTokens: number, outTokens: number, hitTokens: number, missTokens: number) => void,
    onReasoning: (text: string) => void): Promise<void> {
    const req: http.HttpRequest = http.createHttp();
    this.req = req;

    const body: RequestBody = {
      model: model,
      messages: messages,
      stream: true,
      temperature: 0.7
    };
    // 推理等级：off=关闭思考；low/high/max=开启思考并指定强度
    if (effort === 'off') {
      const t: Thinking = { type: 'disabled' };
      body.thinking = t;
    } else {
      const t: Thinking = { type: 'enabled' };
      body.thinking = t;
      body.reasoning_effort = effort;
    }

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + apiKey,
      'Accept': 'text/event-stream'
    };

    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: JSON.stringify(body),
      connectTimeout: 60000,
      readTimeout: 180000
    };

    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });

    return new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
      let buffer: string = '';
      let raw: string = '';
      let finished: boolean = false;

      const finish = (err?: Error): void => {
        if (finished) {
          return;
        }
        finished = true;
        try {
          req.off('dataReceive');
        } catch (e) {
        }
        try {
          req.destroy();
        } catch (e) {
        }
        if (this.req === req) {
          this.req = undefined;
        }
        if (err !== undefined) {
          reject(err);
        } else {
          resolve();
        }
      };

      // 每收到一段字节，先攒进 buffer，再按行解析 SSE
      req.on('dataReceive', (data: ArrayBuffer) => {
        let piece: string = '';
        try {
          piece = decoder.decodeToString(new Uint8Array(data), { stream: true });
        } catch (e) {
          piece = '';
        }
        raw += piece;
        buffer += piece;

        let idx: number = buffer.indexOf('\n');
        while (idx >= 0) {
          const line: string = buffer.substring(0, idx).trim();
          buffer = buffer.substring(idx + 1);
          idx = buffer.indexOf('\n');

          if (!line.startsWith('data:')) {
            continue;
          }
          const payload: string = line.substring(5).trim();
          if (payload.length === 0 || payload === '[DONE]') {
            continue;
          }
          try {
            const chunk: Chunk = JSON.parse(payload) as Chunk;
            if (chunk.choices !== undefined && chunk.choices.length > 0) {
              const choice: Choice = chunk.choices[0];
              // 思考过程（V4 思考模式）：reasoning_content
              if (choice.delta !== undefined && choice.delta.reasoning_content !== undefined
                && choice.delta.reasoning_content !== null) {
                onReasoning(choice.delta.reasoning_content);
              }
              // 正文：注意 content 可能是 null（思考阶段），必须排除 null 和 undefined
              if (choice.delta !== undefined && choice.delta.content !== undefined
                && choice.delta.content !== null) {
                onDelta(choice.delta.content);
              }
            }
            if (chunk.usage !== undefined) {
              const u: Usage = chunk.usage;
              const inTok: number = u.prompt_tokens !== undefined ? u.prompt_tokens : 0;
              const outTok: number = u.completion_tokens !== undefined ? u.completion_tokens : 0;
              const hitTok: number = u.prompt_cache_hit_tokens !== undefined ? u.prompt_cache_hit_tokens : 0;
              const missTok: number = u.prompt_cache_miss_tokens !== undefined ? u.prompt_cache_miss_tokens : (inTok - hitTok);
              onUsage(inTok, outTok, hitTok, missTok);
            }
          } catch (e) {
            // 半截 JSON 或者非数据行，直接跳过
          }
        }
      });

      req.requestInStream(this.chatEndpoint(), options, (err: BusinessError, responseCode: number) => {
        if (err) {
          finish(new Error('网络错误：' + err.message));
          return;
        }
        if (responseCode !== 200) {
          let msg: string = 'HTTP ' + responseCode;
          try {
            const eb: ErrorBody = JSON.parse(raw) as ErrorBody;
            if (eb.error !== undefined && eb.error.message !== undefined) {
              msg = eb.error.message;
            }
          } catch (e) {
          }
          finish(new Error(msg));
          return;
        }
        finish();
      });
    });
  }

  /** 查询当前 Key 可用的模型列表（GET /models） */
  async listModels(apiKey: string): Promise<string[]> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'Authorization': 'Bearer ' + apiKey,
        'Accept': 'application/json'
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 15000,
        readTimeout: 30000
      };
      const resp = await req.request(this.modelsEndpoint(), options);
      if (resp.responseCode !== 200) {
        let msg: string = 'HTTP ' + resp.responseCode;
        try {
          const eb: ErrorBody = JSON.parse(resp.result as string) as ErrorBody;
          if (eb.error !== undefined && eb.error.message !== undefined) {
            msg = eb.error.message;
          }
        } catch (e) {
        }
        throw new Error(msg);
      }
      const body: ModelListResp = JSON.parse(resp.result as string) as ModelListResp;
      const ids: string[] = [];
      if (body.data !== undefined) {
        for (let i: number = 0; i < body.data.length; i++) {
          const it: ModelItem = body.data[i];
          if (it.id !== undefined) {
            ids.push(it.id);
          }
        }
      }
      return ids;
    } finally {
      req.destroy();
    }
  }

  /**
   * 一次性（非流式）调用，用于后台小任务：
   * 记忆整理、主动消息生成、关系档案更新。
   * 刻意不使用 this.req，避免和正在进行的聊天互相打断。
   */
  async chatOnce(apiKey: string, model: string, messages: ChatMessage[],
    temperature: number, maxTokens: number, jsonMode: boolean): Promise<string> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + apiKey,
        'Accept': 'application/json'
      };
      const body: OnceBody = {
        model: model,
        messages: messages,
        stream: false,
        temperature: temperature,
        max_tokens: maxTokens,
        thinking: { type: 'disabled' }
      };
      if (jsonMode) {
        const fmt: OnceFormat = { type: 'json_object' };
        body.response_format = fmt;
      }

      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: JSON.stringify(body),
        connectTimeout: 20000,
        readTimeout: 90000
      };
      const resp = await req.request(this.chatEndpoint(), options);
      if (resp.responseCode !== 200) {
        let msg: string = 'HTTP ' + resp.responseCode;
        try {
          const eb: ErrorBody = JSON.parse(resp.result as string) as ErrorBody;
          if (eb.error !== undefined && eb.error.message !== undefined) {
            msg = eb.error.message;
          }
        } catch (e) {
        }
        throw new Error(msg);
      }
      const parsed: NonStreamResp = JSON.parse(resp.result as string) as NonStreamResp;
      if (parsed.choices === undefined || parsed.choices.length === 0) {
        return '';
      }
      const c: NonStreamChoice = parsed.choices[0];
      if (c.message === undefined || c.message.content === undefined) {
        return '';
      }
      return c.message.content;
    } finally {
      req.destroy();
    }
  }

  /** 用户点“停止”时中断当前请求 */
  abort(): void {
    const r: http.HttpRequest | undefined = this.req;
    this.req = undefined;
    if (r !== undefined) {
      try {
        r.destroy();
      } catch (e) {
      }
    }
  }
}
