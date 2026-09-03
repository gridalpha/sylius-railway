<?php

declare(strict_types=1);

namespace App\Command;

use Doctrine\ORM\EntityManagerInterface;
use Sylius\Component\Core\Model\AdminUser;
use Sylius\Component\Core\Model\AdminUserInterface;
use Sylius\Component\Core\Model\Channel;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\ArrayInput;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;

/**
 * Idempotent boot-time setup for the Railway deployment.
 *
 * Sylius' own `sylius:install:setup --no-interaction` seeds the channel,
 * currency and locale, but it also creates the documented sylius@example.com /
 * sylius administrator. This command runs it only while no channel exists and
 * then converts that account into the operator's own before anything is
 * listening, so the shipped credentials are never reachable.
 *
 * It never touches an administrator that already exists, so a password changed
 * in the admin panel survives every redeploy.
 */
#[AsCommand(
    name: 'railway:bootstrap',
    description: 'Seeds the default channel and the operator administrator account.',
)]
final class RailwayBootstrapCommand extends Command
{
    private const INSTALLER_ADMIN_EMAIL = 'sylius@example.com';

    public function __construct(private readonly EntityManagerInterface $entityManager)
    {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this->addOption(
            'purge-other-admins',
            null,
            InputOption::VALUE_NONE,
            'Disable and re-randomise every administrator other than the configured one (first boot only).',
        );
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $io = new SymfonyStyle($input, $output);

        $email = strtolower(trim((string) ($_SERVER['SYLIUS_ADMIN_EMAIL'] ?? $_ENV['SYLIUS_ADMIN_EMAIL'] ?? '')));
        if ('' === $email) {
            $email = 'admin@example.com';
        }

        $password = (string) ($_SERVER['SYLIUS_ADMIN_PASSWORD'] ?? $_ENV['SYLIUS_ADMIN_PASSWORD'] ?? '');
        if ('' === $password) {
            $io->error('SYLIUS_ADMIN_PASSWORD is not set; refusing to create an administrator.');

            return Command::FAILURE;
        }

        $channelRepository = $this->entityManager->getRepository(Channel::class);
        if (null === $channelRepository->findOneBy([])) {
            $io->writeln('No channel found — running sylius:install:setup.');

            $setup = $this->getApplication()?->find('sylius:install:setup');
            if (null === $setup) {
                $io->error('sylius:install:setup is not available.');

                return Command::FAILURE;
            }

            $setupInput = new ArrayInput(['--no-interaction' => true]);
            $setupInput->setInteractive(false);

            $exitCode = $setup->run($setupInput, $output);
            if (Command::SUCCESS !== $exitCode) {
                return $exitCode;
            }
        }

        $adminRepository = $this->entityManager->getRepository(AdminUser::class);

        /** @var AdminUserInterface|null $admin */
        $admin = $adminRepository->findOneBy(['email' => $email]);

        if (null === $admin) {
            /** @var AdminUserInterface|null $installerAdmin */
            $installerAdmin = $adminRepository->findOneBy(['email' => self::INSTALLER_ADMIN_EMAIL]);

            $admin = $installerAdmin ?? new AdminUser();
            $admin->setEmail($email);
            $admin->setEmailCanonical($email);
            $admin->setUsername($email);
            $admin->setUsernameCanonical($email);
            $admin->setPlainPassword($password);
            $admin->setEnabled(true);

            $this->entityManager->persist($admin);
            $this->entityManager->flush();

            $io->success(sprintf('Administrator "%s" is ready.', $email));
        } else {
            $io->writeln(sprintf('Administrator "%s" already exists — left untouched.', $email));
        }

        if ($input->getOption('purge-other-admins')) {
            $disabled = 0;
            foreach ($adminRepository->findAll() as $other) {
                if ($other === $admin) {
                    continue;
                }

                $other->setEnabled(false);
                $other->setPlainPassword(bin2hex(random_bytes(24)));
                ++$disabled;
            }

            if ($disabled > 0) {
                $this->entityManager->flush();
                $io->writeln(sprintf('Disabled %d administrator account(s) seeded by the installer.', $disabled));
            }
        }

        return Command::SUCCESS;
    }
}
