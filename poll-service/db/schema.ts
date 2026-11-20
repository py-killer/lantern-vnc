import { sqliteTable, text, integer, index, primaryKey } from 'drizzle-orm/sqlite-core';
export const events = sqliteTable('events', {
 id: text('id').primaryKey(), dataset: text('dataset').notNull(), visitor: text('visitor').notNull(),
 type: text('type').notNull(), path: text('path').notNull(), source: text('source').notNull(),
 country: text('country').notNull(), campaign: text('campaign').notNull(), created: integer('created').notNull(),
}, t => [index('events_dataset_created').on(t.dataset,t.created),index('events_visitor_created').on(t.visitor,t.created)]);
export const votes = sqliteTable('votes', {
 dataset:text('dataset').notNull(), visitor:text('visitor').notNull(), eventId:text('event_id').notNull(),
 usefulness:text('usefulness').notNull(), intent:text('intent').notNull(), created:integer('created').notNull(),
}, t => [primaryKey({columns:[t.dataset,t.visitor]})]);
export const feedback = sqliteTable('feedback', {
 id:text('id').primaryKey(), dataset:text('dataset').notNull(), visitor:text('visitor').notNull(),
 kind:text('kind').notNull(), message:text('message').notNull(), created:integer('created').notNull(),
 status:text('status').notNull().default('new'), githubUrl:text('github_url'),
},t => [index('feedback_dataset_created').on(t.dataset,t.created)]);
