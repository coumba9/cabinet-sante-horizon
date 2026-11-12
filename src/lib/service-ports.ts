import { supabase } from './supabase';

export type MessageInput = { appointmentId: string; content: string };

// Port de messagerie : l’implémentation actuelle stocke les échanges dans Supabase.
export interface MessagingService {
  send(input: MessageInput): Promise<void>;
}
export class DatabaseMessagingService implements MessagingService {
  async send(input: MessageInput) {
    if (!supabase) throw new Error('Messagerie non configurée.');
    const { error } = await supabase.rpc('send_appointment_message', { p_appointment_id: input.appointmentId, p_content: input.content });
    if (error) throw new Error('Impossible d’envoyer ce message.');
  }
}

