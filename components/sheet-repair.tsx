'use client';

import {useState} from 'react';
import {supabase} from '../lib/supabase';

const fields = [
  [0, 'Nome Completo'], [1, 'Telefone'], [2, 'Camisa Desejado Sorteio'],
  [3, 'Time(s)'], [4, 'Tamanho'], [5, 'Data de aniversário'], [6, 'Já comprou?'],
  [7, 'Aceita Mensagens?'], [10, 'Possui Indicações?'], [11, 'Total Comprado'],
  [12, 'Número de Pedidos'], [13, 'Última Compra'], [15, 'Tipos de camisa']
] as const;

type SheetIssue = {
  id: string;
  field: string;
  message: string;
  sheet_cells: string[] | null;
  sheet_repairs: {status: 'pending' | 'applied' | 'rejected'; message: string | null} | null;
};

export default function SheetRepair({issue, onQueued}: {issue: SheetIssue; onQueued: () => void}) {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const cells = issue.sheet_cells;
  const duplicate = /duplicad|^Duas linhas correspondem/i.test(issue.message);

  async function submit(changes: Record<string, string>, discard = false) {
    setBusy(true);
    setError('');
    try {
      const result = await supabase!.rpc('request_sheet_repair', {
        issue: issue.id, expected: cells, changes, discard
      });
      if (result.error) throw new Error(result.error.message);
      setOpen(false);
      onQueued();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Não foi possível enviar a correção.');
    } finally {
      setBusy(false);
    }
  }

  if (issue.sheet_repairs?.status === 'pending') return <p role="status">Correção aguardando sincronização.</p>;
  if (!cells) return <p>{issue.field === 'Estrutura da planilha'
    ? 'A integração precisa de revisão. Avise a equipe responsável pela sincronização.'
    : 'Aguarde a próxima sincronização para carregar os dados da linha.'}</p>;

  const orderedFields = [...fields].sort((left, right) =>
    Number(right[1] === issue.field) - Number(left[1] === issue.field)
  );

  return <div>
    {issue.sheet_repairs?.status === 'rejected' && <p className="alert" role="alert">{issue.sheet_repairs.message}</p>}
    {error && <p className="alert" role="alert">{error}</p>}
    <button type="button" className="secondary" aria-expanded={open} onClick={() => setOpen(value => !value)}>
      {open ? 'Fechar edição' : 'Corrigir no dashboard'}
    </button>
    {open && <form className="sheet-repair-form" key={JSON.stringify(cells)} onSubmit={event => {
      event.preventDefault();
      const values = new FormData(event.currentTarget);
      const changes: Record<string, string> = {};
      for (const [index] of fields) {
        const value = String(values.get(String(index)) ?? '').trim();
        if (value !== cells[index].trim()) changes[index] = value;
      }
      if (values.get('clear_id')) changes[8] = '';
      void submit(changes);
    }}>
      <div className="form-grid">
        {orderedFields.map(([index, label]) => <label key={index}>
          {label}
          <input name={String(index)} defaultValue={cells[index]} maxLength={5000} required={index === 0 || index === 1}/>
        </label>)}
      </div>
      {cells[8] && (duplicate || issue.field === 'ID Cliente') && <label className="check">
        <input name="clear_id" type="checkbox"/> Remover o ID Cliente desta linha e identificar o contato pelo telefone
      </label>}
      <p>A próxima sincronização aplica a correção ao Sheets e confere o cadastro.</p>
      <div className="toolbar">
        <button disabled={busy}>Salvar correção</button>
        {duplicate && <button type="button" className="secondary" disabled={busy} onClick={() => {
          if (confirm('Descartar esta linha duplicada da planilha? O cadastro e o histórico no dashboard serão preservados.')) void submit({}, true);
        }}>Descartar linha duplicada</button>}
      </div>
    </form>}
  </div>;
}
