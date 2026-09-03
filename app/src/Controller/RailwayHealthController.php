<?php

declare(strict_types=1);

namespace App\Controller;

use Doctrine\DBAL\Connection;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\Routing\Attribute\Route;

/**
 * Railway's health prober is anonymous and speaks plain HTTP, and the path it
 * is given may only contain letters, digits, "/" and "_". This one boots the
 * kernel and touches the database, so it fails when the app is broken rather
 * than only when the container is gone.
 */
final class RailwayHealthController
{
    #[Route(path: '/healthz', name: 'railway_health', methods: ['GET'])]
    public function __invoke(Connection $connection): JsonResponse
    {
        $connection->executeQuery('SELECT 1');

        return new JsonResponse(['status' => 'ok']);
    }
}
