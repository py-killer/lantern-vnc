CREATE TABLE `events` (
	`id` text PRIMARY KEY NOT NULL,
	`dataset` text NOT NULL,
	`visitor` text NOT NULL,
	`type` text NOT NULL,
	`path` text NOT NULL,
	`source` text NOT NULL,
	`country` text NOT NULL,
	`campaign` text NOT NULL,
	`created` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `events_dataset_created` ON `events` (`dataset`,`created`);--> statement-breakpoint
CREATE INDEX `events_visitor_created` ON `events` (`visitor`,`created`);--> statement-breakpoint
CREATE TABLE `feedback` (
	`id` text PRIMARY KEY NOT NULL,
	`dataset` text NOT NULL,
	`visitor` text NOT NULL,
	`kind` text NOT NULL,
	`message` text NOT NULL,
	`created` integer NOT NULL,
	`status` text DEFAULT 'new' NOT NULL,
	`github_url` text
);
--> statement-breakpoint
CREATE INDEX `feedback_dataset_created` ON `feedback` (`dataset`,`created`);--> statement-breakpoint
CREATE TABLE `votes` (
	`dataset` text NOT NULL,
	`visitor` text NOT NULL,
	`event_id` text NOT NULL,
	`usefulness` text NOT NULL,
	`intent` text NOT NULL,
	`created` integer NOT NULL,
	PRIMARY KEY(`dataset`, `visitor`)
);
