// Protocol-only fixture: real Pi session/UI and scheduling, deterministic provider.
// Authorized for delivery proof in a real Pi TUI; exercises no model provider.
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai/compat';
import { appendFileSync } from 'node:fs';
export default function (pi: any) {
  // Synthetic guest proof only. Never loaded by the shipping wrapper.
  for (const event of ['session_start', 'message_start', 'message_end', 'agent_start', 'agent_settled']) {
    pi.on(event, (value: any, ctx: any) => {
      const path = process.env.C11_PI_PROOF_LOG;
      if (!path) return;
      const message = value?.message;
      const text = typeof message?.content === 'string' ? message.content : message?.content?.map((part: any) => part.text ?? '').join('');
      appendFileSync(path, JSON.stringify({at: Date.now(), event, role: message?.role, text, editor: ctx.ui.getEditorText(), idle: ctx.isIdle()}) + '\n');
    });
  }
  pi.registerProvider('c11-spike', {
    baseUrl: 'http://unused.invalid', apiKey: 'fixture-not-a-credential', api: 'c11-spike-api',
    models: [{id: 'fixture', name: 'Controlled protocol fixture', reasoning:false, input:['text'], cost:{input:0,output:0,cacheRead:0,cacheWrite:0}, contextWindow:200000, maxTokens:1024}],
    streamSimple(model: any, context: any) {
      const stream = createAssistantMessageEventStream();
      const latest = [...context.messages].reverse().find((m:any) => m.role === 'user');
      const text = typeof latest?.content === 'string' ? latest.content : latest?.content?.map((p:any) => p.text ?? '').join('');
      const message:any = {role:'assistant',content:[{type:'text',text:''}],api:model.api,provider:model.provider,model:model.id,usage:{input:1,output:1,cacheRead:0,cacheWrite:0,totalTokens:2,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:'stop',timestamp:Date.now()};
      queueMicrotask(() => {
        stream.push({type:'start',partial:message});
        stream.push({type:'text_start',contentIndex:0,partial:message});
        setTimeout(() => {
          message.content[0].text = text === 'c11 mail waiting: run c11 mailbox recv --ack' ? 'C11_PI_DOORBELL_ACCEPTED' : 'COMPLETED: ' + text;
          stream.push({type:'text_delta',contentIndex:0,delta:message.content[0].text,partial:message});
          stream.push({type:'text_end',contentIndex:0,content:message.content[0].text,partial:message});
          stream.push({type:'done',reason:'stop',message});
          stream.end();
        }, text?.startsWith('BUSY') ? 8000 : 150);
      });
      return stream;
    }
  });
}
