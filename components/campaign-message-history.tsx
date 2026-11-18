'use client';

import {useEffect, useState, type FormEvent} from 'react';
import {supabase} from '../lib/supabase';

type Version = {
  message_id: string;
  message_position: number;
  kind: 'text' | 'image' | 'video' | 'audio';
  revision: number;
  is_current: boolean;
  body: string | null;
  created_at: string;
  sent: number;
  delivered: number;
  read: number;
  attempts: number;
};

type Dispatch = {
  dispatch_id: string;
  contact_name: string;
  phone: string;
  status: 'sending' | 'accepted' | 'unknown';
  sent_at: string | null;
  delivered_at: string | null;
  read_at: string | null;
};

const dateTime = new Intl.DateTimeFormat('pt-BR', {
  dateStyle: 'short', timeStyle: 'short', timeZone: 'America/Sao_Paulo',
});
const kinds = {text: 'Texto', image: 'Imagem', video: 'Vídeo', audio: 'Áudio'};

function RecipientHistory({message, revision}: {message: string; revision: number}) {
  const [page, setPage] = useState(0);
  const [result, setResult] = useState<{page: number; rows: Dispatch[]; error?: string}>();

  useEffect(() => {
    let active = true;
    void supabase!.rpc('campaign_message_recipients', {
      message, version_number: revision, page_number: page,
    }).then(({data, error}) => {
      if (active) setResult({page, rows: data ?? [], error: error?.message});
    });
    return () => {active = false;};
  }, [message, revision, page]);

  if (result?.page !== page) return <p role="status">Carregando destinatários…</p>;
  if (result.error) return <p className="alert" role="alert">{result.error}</p>;
  if (!result.rows.length) return <p>Nenhum destinatário nesta página.</p>;

  return <>
    <div className="table-wrap">
      <table>
        <thead><tr><th scope="col">Contato</th><th scope="col">Telefone</th><th scope="col">Situação</th></tr></thead>
        <tbody>{result.rows.slice(0, 20).map(dispatch => (
          <tr key={dispatch.dispatch_id}>
            <td>{dispatch.contact_name}</td><td>{dispatch.phone}</td>
            <td>{dispatch.read_at ? 'Lido' : dispatch.delivered_at ? 'Entregue' : dispatch.sent_at ? 'Enviado' :
              {sending: 'Em envio', accepted: 'Aceito pelo WhatsApp', unknown: 'Resultado incerto'}[dispatch.status]}</td>
          </tr>
        ))}</tbody>
      </table>
    </div>
    <div className="toolbar">
      {page > 0 && <button className="secondary" onClick={() => setPage(page - 1)}>Anterior</button>}
      {result.rows.length > 20 && <button className="secondary" onClick={() => setPage(page + 1)}>Próxima</button>}
    </div>
  </>;
}

function History({campaign, editable, blocked}: {campaign: string; editable: boolean; blocked: boolean}) {
  const [versions, setVersions] = useState<Version[]>();
  const [editing, setEditing] = useState<Version>();
  const [body, setBody] = useState('');
  const [recipientKey, setRecipientKey] = useState('');
  const [refresh, setRefresh] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  useEffect(() => {
    let active = true;
    void supabase!.rpc('campaign_message_history', {campaign}).then(({data, error}) => {
      if (!active) return;
      if (error) setError(error.message);
      else setVersions(data ?? []);
    });
    return () => {active = false;};
  }, [campaign, refresh]);

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!editing || !editable || blocked || busy) return;

    setBusy(true);
    setError('');
    setNotice('');
    try {
      const {data, error} = await supabase!.rpc('edit_campaign_message', {
        message: editing.message_id, expected_revision: editing.revision, new_body: body,
      });
      if (error) throw new Error(error.message);
      setEditing(undefined);
      setRecipientKey('');
      setVersions(undefined);
      setRefresh(previous => previous + 1);
      setNotice(data === editing.revision ? 'A mensagem já está atualizada.' : 'Nova versão salva para os próximos envios.');
    } catch (error) {
      setError(error instanceof Error ? error.message : 'Não foi possível salvar a mensagem.');
    } finally {
      setBusy(false);
    }
  }

  return <div className="rule-group">
    <h2>Histórico de mensagens</h2>
    {editable && <p>Ao retomar, os envios pendentes usam a versão atual. Envios já iniciados mantêm a versão anterior.</p>}
    {error && <p className="alert" role="alert">{error}</p>}
    {notice && <p className="notice" role="status">{notice}</p>}
    {!versions && !error && <p role="status">Carregando histórico…</p>}
    {versions?.length === 0 && <p>Esta campanha não tem mensagens.</p>}
    {versions?.map(version => {
      const key = version.message_id + '/' + version.revision;
      const showEditor = editable && editing?.message_id === version.message_id && version.is_current;
      return <section className="rule-group" key={key}>
        <div className="toolbar">
          <strong>Mensagem {version.message_position + 1} · {kinds[version.kind]} · Versão {version.revision}{version.is_current && ' (atual)'}</strong>
          <time dateTime={version.created_at}>{dateTime.format(new Date(version.created_at))}</time>
        </div>
        {showEditor ? (
          <form onSubmit={save}>
            <label>{version.kind === 'text' ? 'Texto da mensagem' : 'Legenda da mídia'}
              <textarea value={body} onChange={event => setBody(event.target.value)} disabled={busy} required={version.kind === 'text'} />
            </label>
            <p>Use {'{{nome}}'} para inserir o primeiro nome do contato.</p>
            <div className="toolbar">
              <button disabled={busy || blocked || body === (version.body ?? '') || (version.kind === 'text' && !body.trim())}>
                {busy ? 'Salvando…' : 'Salvar nova versão'}
              </button>
              <button type="button" className="secondary" disabled={busy} onClick={() => {setEditing(undefined); setError('');}}>Fechar edição</button>
            </div>
          </form>
        ) : <>
          <p className="preview" style={{overflowWrap: 'anywhere'}}>{version.body || (version.kind === 'text' ? 'Sem texto' : 'Sem legenda')}</p>
          {editable && version.is_current && <button className="secondary" disabled={busy || blocked} onClick={() => {
            setEditing(version);
            setBody(version.body ?? '');
            setError('');
            setNotice('');
          }}>{version.kind === 'text' ? 'Editar mensagem' : 'Editar legenda'}</button>}
        </>}
        <p>{version.sent} enviados · {version.delivered} entregues · {version.read} lidos</p>
        {version.attempts > 0 && <button className="link" aria-expanded={recipientKey === key} onClick={() => setRecipientKey(recipientKey === key ? '' : key)}>
          {recipientKey === key ? 'Ocultar destinatários' : 'Ver destinatários'}
        </button>}
        {recipientKey === key && <RecipientHistory message={version.message_id} revision={version.revision}/>}
      </section>;
    })}
  </div>;
}

export default function CampaignMessageHistory({id, editable, blocked}: {id: string; editable: boolean; blocked: boolean}) {
  const [open, setOpen] = useState(false);
  return <div>
    <button className="link" aria-expanded={open} onClick={() => setOpen(previous => !previous)}>
      {open ? 'Ocultar histórico de mensagens' : editable ? 'Editar mensagem e ver histórico' : 'Ver histórico de mensagens'}
    </button>
    {open && <History campaign={id} editable={editable} blocked={blocked}/>}
  </div>;
}
