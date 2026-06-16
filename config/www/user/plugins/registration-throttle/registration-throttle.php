<?php

namespace Grav\Plugin;

use Grav\Common\Plugin;
use Grav\Common\Data\ValidationException;
use RocketTheme\Toolbox\Event\Event;

/**
 * Registration Throttle — per-IP rate limit on the membership registration
 * form, an anti-abuse backstop to the honeypot field.
 *
 * Hooks the forms plugin's onFormValidationProcessed (the same event the
 * honeypot uses), so a throttled submission is rejected as a validation error
 * BEFORE the register_user process action runs — no account is created and no
 * activation email is sent. It reuses the login plugin's RateLimiter and its
 * proxy-aware client-IP key (Login::getIpKey -> Uri::ip), so it counts the
 * real visitor IP behind the one.com reverse proxy, not the proxy itself.
 *
 * Fail-open by design: any unexpected error in the throttle path is logged and
 * swallowed so registration still proceeds — a plugin bug must never block
 * legitimate signups. Only the intentional "rate limited" ValidationException
 * propagates to the form.
 */
class RegistrationThrottlePlugin extends Plugin
{
    /**
     * @return array
     */
    public static function getSubscribedEvents(): array
    {
        return [
            // Priority lower than the form plugin's own honeypot check (0), so a
            // honeypot-caught bot is rejected first and never consumes a slot.
            'onFormValidationProcessed' => ['onFormValidationProcessed', -100],
        ];
    }

    /**
     * Reject the submission when the client IP is over the per-window limit.
     *
     * @param Event $event
     * @return void
     * @throws ValidationException
     */
    public function onFormValidationProcessed(Event $event): void
    {
        if ($this->isAdmin()) {
            return;
        }

        $config = (array) $this->grav['config']->get('plugins.registration-throttle');
        if (empty($config['enabled'])) {
            return;
        }

        $form = $event['form'] ?? null;
        $target = $config['form_name'] ?? 'registration';
        if (!$form || !\is_callable([$form, 'getName']) || $form->getName() !== $target) {
            return;
        }

        try {
            $max = (int) ($config['max_count'] ?? 10);
            $interval = (int) ($config['interval'] ?? 60);
            if ($max <= 0) {
                return; // 0 = unlimited (plugin loaded, limit off)
            }

            $login = $this->grav['login'] ?? null;
            if ($login === null
                || !\is_callable([$login, 'getRateLimiter'])
                || !\is_callable([$login, 'getIpKey'])) {
                return; // login plugin supplies the limiter + IP key; fail open
            }

            $ipKey = $login->getIpKey();
            if (!$ipKey) {
                return; // cannot identify the client -> do not throttle
            }

            $limiter = $login->getRateLimiter('register_attempts', $max, $interval);
            $limiter->registerRateLimitedAction($ipKey, 'ip');

            if ($limiter->isRateLimited($ipKey, 'ip')) {
                $message = $config['message']
                    ?? 'For mange medlemskaber er oprettet fra din forbindelse for nylig. Vent venligst et øjeblik og prøv igen.';
                throw new ValidationException($message);
            }
        } catch (ValidationException $e) {
            throw $e; // intentional block — propagate to the form
        } catch (\Throwable $e) {
            // Anything else must not break registration. Log and fail open.
            if (isset($this->grav['log'])) {
                $this->grav['log']->warning('registration-throttle failed open: ' . $e->getMessage());
            }
        }
    }
}
