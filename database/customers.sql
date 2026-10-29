IF OBJECT_ID(N'[__EFMigrationsHistory]') IS NULL
BEGIN
    CREATE TABLE [__EFMigrationsHistory] (
        [MigrationId] nvarchar(150) NOT NULL,
        [ProductVersion] nvarchar(32) NOT NULL,
        CONSTRAINT [PK___EFMigrationsHistory] PRIMARY KEY ([MigrationId])
    );
END;
GO

BEGIN TRANSACTION;
IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261021221818_InitialCustomers'
)
BEGIN
    CREATE TABLE [Customers] (
        [Id] uniqueidentifier NOT NULL,
        [Email] nvarchar(320) NOT NULL,
        [FullName] nvarchar(200) NOT NULL,
        [Address] nvarchar(500) NOT NULL,
        [IsVip] bit NOT NULL,
        [State] nvarchar(32) NOT NULL,
        [CreatedAt] datetime2 NOT NULL,
        CONSTRAINT [PK_Customers] PRIMARY KEY ([Id])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261021221818_InitialCustomers'
)
BEGIN
    CREATE TABLE [Inbox] (
        [Id] nvarchar(128) NOT NULL,
        [ReceivedAt] datetime2 NOT NULL,
        CONSTRAINT [PK_Inbox] PRIMARY KEY ([Id])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261021221818_InitialCustomers'
)
BEGIN
    CREATE TABLE [Outbox] (
        [Id] nvarchar(64) NOT NULL,
        [Type] nvarchar(128) NOT NULL,
        [Payload] nvarchar(max) NOT NULL,
        [CreatedAt] datetime2 NOT NULL,
        [PublishedAt] datetime2 NULL,
        CONSTRAINT [PK_Outbox] PRIMARY KEY ([Id])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261021221818_InitialCustomers'
)
BEGIN
    CREATE TABLE [CustomerCompletedOrders] (
        [CustomerId] uniqueidentifier NOT NULL,
        [OrderId] uniqueidentifier NOT NULL,
        CONSTRAINT [PK_CustomerCompletedOrders] PRIMARY KEY ([CustomerId], [OrderId]),
        CONSTRAINT [FK_CustomerCompletedOrders_Customers_CustomerId] FOREIGN KEY ([CustomerId]) REFERENCES [Customers] ([Id]) ON DELETE CASCADE
    );
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261021221818_InitialCustomers'
)
BEGIN
    CREATE INDEX [IX_CustomerCompletedOrders_OrderId] ON [CustomerCompletedOrders] ([OrderId]);
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261021221818_InitialCustomers'
)
BEGIN
    CREATE UNIQUE INDEX [IX_Customers_Email] ON [Customers] ([Email]);
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261021221818_InitialCustomers'
)
BEGIN
    CREATE INDEX [IX_Outbox_PublishedAt] ON [Outbox] ([PublishedAt]);
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261021221818_InitialCustomers'
)
BEGIN
    INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES (N'20261021221818_InitialCustomers', N'10.0.12');
END;

COMMIT;
GO

