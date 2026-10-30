// Explicit unit-test journal adapter. Real durability tests use MigrationFence.
import {validateFenceEvent,reduceFenceEvents} from '../src/migration-fence-journal.mjs';
export class MemoryPublicationFence{
  events=[];
  async append(event){
    const checked=validateFenceEvent(structuredClone(event)),next=[...this.events,checked];
    reduceFenceEvents(next);this.events=next;
  }
  async snapshot(){return reduceFenceEvents(structuredClone(this.events));}
}
